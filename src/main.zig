const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const icons = @import("icons").tvg;
const fifoasync = @import("fifoasync");
const dvui = @import("dvui");
const tailwind = @import("tailwind");
const util = @import("util.zig");

const Backend = dvui.backend;
const state = @import("state.zig");
const gui = @import("gui.zig");

test "all" {
    std.testing.refAllDecls(@This());
}
const winapi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn AttachConsole(dwProcessId: std.os.windows.DWORD) std.os.windows.BOOL;
} else struct {};
pub fn main() !void {
    try fifoasync.thread.prio.set_realtime_critical_highest();
    comptime std.debug.assert(@hasDecl(Backend, "SDLBackend"));
    if (@import("builtin").os.tag == .windows) _ = winapi.AttachConsole(0xFFFFFFFF);

    std.log.info("SDL version: {}", .{Backend.getSDLVersion()});
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");
    const alloc = gpa_instance.allocator();

    const favicon = @embedFile("assets/favicon.png");
    var backend = try Backend.initWindow(.{
        .allocator = alloc,
        .size = .{ .w = 800.0, .h = 600.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = true,
        .title = "Fly Simulator",
        .icon = favicon,
    });
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer win.deinit();

    try gui.gState.init(alloc, &win, &backend);
    defer gui.gState.deinit();

    const display_id = Backend.c.SDL_GetDisplayForWindow(backend.window);
    if (display_id == 0) return error.NoDisplay;
    const mode: ?*const Backend.c.SDL_DisplayMode = Backend.c.SDL_GetCurrentDisplayMode(display_id);
    if (mode == null) return error.NoDisplayMode;
    const refresh_hz: f32 = mode.?.refresh_rate;
    const fps_target: u64 = @intFromFloat(1_000_000_000.0 / refresh_hz);

    win.debug_events = false;

    var fps_arr: [50]u64 = undefined;
    var fps_arr_i: usize = 0;
    for (&fps_arr) |*f| f.* = 0;

    var fps_timer = try std.time.Timer.start();

    while (gui.gState.running) {
        gui.gState.update();
        _ = Backend.c.SDL_RenderClear(backend.renderer);
        gui.gState.update();

        try win.begin(0);
        gui.gState.event_handler.init_frame_start();
        gui.gState.event_handler.addAllEvents(&gui.gState.running);

        gui.gState.update();

        fps_limiter: while (true) {
            if (fps_timer.read() < fps_target) {
                gui.gState.update();
                var re = std.Thread.ResetEvent{};
                re.timedWait(100_000) catch {};
            } else {
                fps_arr_i = (fps_arr_i + 1) % fps_arr.len;
                fps_arr[fps_arr_i] = fps_timer.read();
                fps_timer.reset();
                break :fps_limiter;
            }
        }

        dvui.themeSet(&dvui.currentWindow().themes.get("Adwaita Light").?);

        gui.gState.update();
        dvui.label(@src(), "FPS: {d:.0}", .{avg_fps_from_arr(&fps_arr)}, .{});

        gui.gState.update();
        try dvui.addFont("base", Font.sf_pro_ttf, null);

        gui.gState.update();
        gui.main() catch |e| {
            std.log.err("{}", .{e});
        };

        gui.gState.update();
        _ = try win.end(.{});

        gui.gState.update();
        try backend.setCursor(win.cursorRequested());
        gui.gState.update();
        try backend.textInputRect(win.textInputRequested());
        gui.gState.update();
        try backend.renderPresent();
    }
}
pub const Font = struct {
    const sf_pro_ttf = @embedFile("assets/SF-Pro.ttf");
};

pub const EventAction = struct {
    ptr: *anyopaque,
    fn_ptr: *const fn (*anyopaque, event: dvui.Event) void,
};
pub const Eventhandler = struct {
    const Task = fifoasync.sched.Task;
    pub const SPSC = fifoasync.spsc.Fifo2(Task);
    const EventListeners = std.ArrayListUnmanaged(EventAction);
    const EventList = std.ArrayListUnmanaged(dvui.Event);
    const Executor = fifoasync.sched.GenericAsyncExecutor(*Eventhandler, async_exe_fn);
    timer: std.time.Timer = undefined,
    fifo: SPSC = undefined,
    win: *dvui.Window,
    backend: *dvui.backend,
    cmd_buffer: [2]EventListeners = .{ .{}, .{} },
    events_buffer: EventList = undefined,
    prepare_buffer: *EventListeners = undefined,
    ready_buffer: *EventListeners = undefined,
    low_latency_exe: Executor = undefined,
    event_idx_offset: usize = 0,
    pub fn async_exe_fn(t: **Eventhandler, task: Task) anyerror!void {
        try t.*.fifo.push(task);
    }
    pub fn init(
        self: *Eventhandler,
        alloc: Allocator,
        rt_task_capacity: usize,
        win: *dvui.Window,
        backend: *dvui.backend,
        event_listeners_max: usize,
    ) !void {
        self.timer = try .start();
        self.win = win;
        self.backend = backend;
        self.cmd_buffer[0] = try .initCapacity(alloc, event_listeners_max);
        self.cmd_buffer[1] = try .initCapacity(alloc, event_listeners_max);
        self.prepare_buffer = &self.cmd_buffer[0];
        self.ready_buffer = &self.cmd_buffer[1];
        self.fifo = try .init(alloc, rt_task_capacity);
        self.events_buffer = try .initCapacity(alloc, 4096);
        self.low_latency_exe = Executor{
            .inner = self,
        };
    }
    pub fn deinit(self: *Eventhandler, alloc: Allocator) void {
        defer self.ready_buffer.deinit(alloc);
        defer self.prepare_buffer.deinit(alloc);
        defer self.fifo.deinit(alloc);
        defer self.events_buffer.deinit(alloc);
    }
    /// call this once every frame, i.e. for a button that wants to get called back when new
    /// events come in between frames
    /// event listeners are flushed per frame thus "one frame behind"
    pub fn add_event_listener(self: *Eventhandler, action: EventAction) void {
        if (self.prepare_buffer.items.len < self.prepare_buffer.capacity) {
            self.prepare_buffer.appendAssumeCapacity(action);
        } else {
            std.log.warn("event listener max capacity breached", .{});
        }
    }
    /// call this at the start of the frame!
    /// this makes the list of Event Listeners of the last frame visible
    pub fn init_frame_start(self: *Eventhandler) void {
        std.mem.swap(*EventListeners, &self.prepare_buffer, &self.ready_buffer);
        self.prepare_buffer.clearRetainingCapacity();
    }
    /// call this right after win.begin
    pub fn addAllEvents(self: *Eventhandler, running: *bool) void {
        self.check_events(running);
        while (self.events_buffer.pop()) |_| {}
        self.event_idx_offset = 0;
    }
    /// fetches dvui events but caches them so that they are added with the next addAllEvents call
    /// call this regularly to handle events in between frames
    pub fn check_events(self: *Eventhandler, running: *bool) void {
        self.do_tasks();
        const lenA = self.win.events.items.len;
        const quit = self.backend.addAllEvents(self.win) catch true;
        if (quit) {
            running.* = false;
            return;
        }
        for (self.win.events.items[lenA..]) |ev| {
            if (self.events_buffer.items.len < self.events_buffer.capacity) {
                self.events_buffer.appendAssumeCapacity(ev);
            } else {
                std.log.warn("event list max capacity was breached", .{});
            }
        }
        self.process_events();
        self.do_tasks();
    }
    /// does background realtime tasks
    pub inline fn do_tasks(self: *Eventhandler) void {
        while (self.fifo.pop()) |t| t.call();
    }
    /// call all event handlers so they get to process an event
    inline fn process_events(self: *Eventhandler) void {
        self.event_idx_offset = @min(self.event_idx_offset, self.events_buffer.items.len);
        for (self.events_buffer.items[self.event_idx_offset..]) |ev| {
            if (ev.handled) continue;
            for (self.ready_buffer.items) |ea| {
                @call(.auto, ea.fn_ptr, .{ ea.ptr, ev });
            }
        }
        self.event_idx_offset = self.events_buffer.items.len;
    }
};

fn avg_fps_from_arr(arr: []u64) f64 {
    var avg: u64 = 0;
    for (arr) |f| avg += f;
    avg /= arr.len;
    const avgf: f64 = @floatFromInt(avg);
    return 1_000_000_000.0 / avgf;
}
