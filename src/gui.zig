const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const icons = @import("icons").tvg;
const dvui = @import("dvui");
const tailwind = @import("tailwind");
const util = @import("util.zig");

const State = @import("state.zig").App;

pub var gState: State = .{};
const pad_layout = &gState.pad_layout;
const colors = &gState.color_settings;
const Mode = enum {
    benchmarking,
};
var mode: Mode = .benchmarking;

const Stat = struct {
    const n = 100;
    i: usize = 0,
    time: [n]u64 = undefined,
    current_max: u64 = 0,
    alltime_max: u64 = 0,
    fn update(self: *Stat, function: anytype) void {
        var t = std.time.Timer.start() catch unreachable;
        function();
        const tval = t.read();
        self.time[self.i] = tval;
        if (self.i + 1 == n) {
            self.i = 0;
            self.current_max = std.mem.max(u64, &self.time);
            self.alltime_max = @max(self.alltime_max, self.current_max);
        } else {
            self.i += 1;
        }
    }
};

fn ns_to_us(ns: u64) f64 {
    var k: f64 = @floatFromInt(ns);
    k /= 1_000.0;
    return k;
}
pub fn main() !void {
    var box = dvui.box(@src(), .vertical, .{
        .expand = .both,
        .color_fill = colors.bg_color,
        .background = true,
        .color_fill_hover = .red,
    });
    defer box.deinit();
    dvui.label(@src(), "test preferably in release", .{}, .{});
    gState.update();
    if (gState.fast_event_handling) {
        dvui.label(@src(), "Click the gray Area - Fast Event Handling with callbacks (a bit buggy wiht note off)", .{}, .{});
    } else {
        dvui.label(@src(), "Click the gray Area - Normal dvui Event Handling", .{}, .{});
    }
    gState.update();
    if (dvui.button(@src(), "togle fast event handling", .{}, .{})) {
        gState.fast_event_handling = !gState.fast_event_handling;
    }
    gState.update();
    pad.draw();
}

var pad: DragPad = .{};

pub const DragPad = struct {
    wd: ?dvui.WidgetData = null,
    pub fn draw(self: *@This()) void {
        const bb = dvui.box(@src(), .horizontal, .{
            .expand = .both,
            .margin = .all(50),
            .background = true,
            .color_fill = .fromHex(tailwind.slate600),
            .corner_radius = .all(10),
        });
        defer bb.deinit();
        self.wd = bb.widget().data().*;
        if (gState.fast_event_handling) {
            self.register();
        } else {
            for (dvui.currentWindow().events.items) |ev| {
                processEvent(@ptrCast(self), ev);
            }
        }
    }
    pub fn register(self: *@This()) void {
        gState.event_handler.add_event_listener(.{ .fn_ptr = processEvent, .ptr = @ptrCast(self) });
    }
    pub fn processEvent(any: *anyopaque, evt: dvui.Event) void {
        const self: *@This() = @alignCast(@ptrCast(any));
        const synth = &gState.playback.synth;
        switch (evt.evt) {
            .mouse => |m| {
                const mo: dvui.Event.Mouse = m;
                const pos: dvui.Point.Physical = mo.p;
                if (self.wd == null) return;
                const r = self.wd.?.borderRectScale().r;
                if (!r.contains(pos)) {
                    synth.action.store(.end);
                    return;
                }
                const rely = (pos.x - r.x) / r.w;
                const relx = (pos.y - r.y) / r.h;
                const base_freq = 50.0;
                synth.frequency.store(base_freq * std.math.pow(f64, 2.5, 1.0 - relx));

                synth.girth.store(rely);

                switch (mo.action) {
                    // // Focus events come right before their associated pointer event, usually
                    // // leftdown/rightdown or motion. Separated to enable changing what
                    // // causes focus changes.
                    // focus,
                    // press,
                    // release,
                    // wheel_x: f32,
                    // wheel_y: f32,
                    // // motion Point is the change in position
                    // // if you just want to react to the current mouse position if it got
                    // // moved at all, use the .position event with mouseTotalMotion()
                    // motion: dvui.Point.Physical,
                    // // always a single position event per frame, and it's always after all
                    // // other events, used to change mouse cursor and do widget highlighting
                    // // - also useful with mouseTotalMotion() to respond to mouse motion but
                    // // only at the final location
                    // // - generally you don't want to mark this as handled, the exception is
                    // // if you are covering up child widgets and don't want them to react to
                    // // the mouse hovering over them
                    // // - instead, call dvui.cursorSet()
                    // position,
                    .press => {
                        synth.action.store(.start);
                    },
                    .release => {
                        synth.action.store(.end);
                    },
                    else => {},
                }
            },
            .key => |k| {
                std.log.warn("key", .{});
                switch (k.action) {
                    .down => {
                        synth.action.store(.start);
                    },
                    .up => {
                        synth.action.store(.end);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};
