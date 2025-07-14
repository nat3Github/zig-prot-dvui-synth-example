const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;

const icons = @import("icons").tvg;
const dvui = @import("dvui");
const tailwind = @import("tailwind");
const fifoasync = @import("fifoasync");
const util = @import("util.zig");
const portaudio = @import("portaudio");

const Backend = dvui.backend;
const EventHandler = @import("main.zig").Eventhandler;

const AsyncExecutor = fifoasync.sched.AsyncExecutor;

pub const Sched = struct {
    pool: std.Thread.Pool = undefined,

    pub fn init(self: *@This(), alloc: Allocator) !void {
        const cpu_cores = std.Thread.getCpuCount() catch 4;
        try self.pool.init(.{ .allocator = alloc, .n_jobs = cpu_cores });
        errdefer self.pool.deinit();
    }
    pub fn deinit(self: *@This(), alloc: Allocator) void {
        _ = alloc;
        defer self.pool.deinit();
    }
};

pub const Playback = struct {
    pa: portaudio.PortAudio = undefined,
    sw: portaudio.TStreamF32 = undefined,
    sw_active: bool = false,
    callback_frames: usize = 64,
    callback_srate: u32 = 48000,
    alloc: Allocator = undefined,
    synth: Synth = .{},
    pub fn init(self: *@This(), alloc: Allocator) !void {
        self.pa = try portaudio.PortAudio.init();
        errdefer self.pa.deinit();
        self.alloc = alloc;
        self.start_stream() catch {};
    }
    pub fn deinit(self: *@This()) void {
        assert(self.sw_active == false); // call stop_stream and finish all backround tasks
        // const alloc = self.alloc;
        self.pa.deinit();
    }
    pub fn start_stream(self: *@This()) !void {
        if (self.sw_active) self.stop_stream();
        const def_out_device_idx = try self.pa.index_of_default_output_device();
        const def_out_info = self.pa.get_device_info(def_out_device_idx);
        const req_srate: f64 = @floatFromInt(self.callback_srate);
        std.log.warn("default device: {s}", .{def_out_info.name});
        std.log.warn("default device samplerate: {d:.3}", .{def_out_info.defaultSampleRate});

        const def_in_device_idx = try self.pa.index_of_default_input_device();
        const def_in_info = self.pa.get_device_info(def_in_device_idx);

        const in_channels: usize = @intCast(def_in_info.maxInputChannels);
        const out_channels: usize = @intCast(def_out_info.maxOutputChannels);

        try self.sw.init(
            self,
            @This().callback,
            null,
            def_in_device_idx,
            in_channels,
            def_out_device_idx,
            out_channels,
            req_srate,
            self.callback_frames,
        );
        try self.sw.stream.start();
        self.sw_active = true;
    }

    pub fn stop_stream(self: *@This()) void {
        if (self.sw_active == false) return;
        self.sw.stream.stop() catch {};
        self.sw_active = false;
    }
    pub fn callback(xself: *anyopaque, _: []const f32, out: []f32, frames: usize) void {
        const self: *@This() = @alignCast(@ptrCast(xself));
        self.synth.callback(out, frames);
    }
};

pub const Synth = struct {
    const Action = enum(u8) {
        none,
        start,
        end,
    };
    const Envelope = enum(u8) {
        none,
        start,
        attack,
        decay,
        release,
        releasing,
    };
    const Atomic = fifoasync.util.atomic.AcqRelAtomic;
    const SRATE = 48000.0;
    frequency: Atomic(f64) = .init(300),
    volume: Atomic(f64) = .init(1),
    girth: Atomic(f64) = .init(0.0), // 0.0 to 1.0, 0.0 being clean, 1.0 being full grit
    // volume: Atomic(f64) = .init(0.0), // 0.0 to 1.0
    sample_rate: f64 = SRATE, // Standard audio sample rate
    phase: f64 = 0.0, // Current phase of the oscillator
    vol: f64 = 0.0,
    action: Atomic(Action) = .init(.none),

    env: Envelope = .none,
    counter: u64 = 0,
    ran: std.Random.DefaultPrng = .init(0),

    pub fn callback(self: *Synth, out: []f32, frames: usize) void {
        const channels = out.len / frames;
        const current_frequency = self.frequency.load();

        const action = self.action.load();
        if (action == .start) {
            self.env = .start;
            self.action.store(.none);
        }
        if (action == .end) {
            self.env = .release;
            self.action.store(.none);
        }

        const phase_increment = (std.math.pi * 2.0 * current_frequency) / self.sample_rate;
        for (0..frames) |frame| {
            const current_girth = std.math.pow(f64, self.girth.load(), 2);

            switch (self.env) {
                .none => self.vol = 0,
                .start => {
                    self.counter = 0;
                    self.env = .attack;
                },
                .attack => {
                    if (self.vol < 1.0) {
                        self.vol += 1.0 / 100.0;
                    } else {
                        self.env = .decay;
                    }
                },
                .decay => {
                    if (self.vol > 0.5) {
                        self.vol -= 1.0 / 5000.0;
                    }
                },
                .release => {
                    self.counter = 0;
                    self.env = .releasing;
                },
                .releasing => {
                    if (self.vol > 0) {
                        self.vol -= 1.0 / 10000.0;
                    } else {
                        self.vol = 0.0;
                    }
                },
            }
            self.counter += 1;

            const current_volume = self.vol;

            var sample: f32 = @floatCast(std.math.sin(self.phase));

            sample = self.applyWaveshaping(sample, current_girth);

            sample *= @floatCast(current_volume);

            for (0..channels) |ch| {
                out[frame * channels + ch] = @floatCast(sample);
            }

            self.phase += phase_increment;
            if (self.phase >= std.math.pi * 2.0) {
                self.phase -= std.math.pi * 2.0;
            }
        }
    }
    pub fn applyWaveshaping(self: *Synth, sample: f32, strength: f64) f32 {
        const clamped_strength = @as(f32, @floatCast(std.math.clamp(strength, 0.0, 1.0)));
        var distorted_sample = sample;
        distorted_sample += (self.ran.random().float(f32) - 0.5) * clamped_strength;
        distorted_sample = std.math.pow(f32, distorted_sample * (1.0 + clamped_strength), 2);
        distorted_sample = std.math.clamp(distorted_sample, -1.0, 1.0);
        return distorted_sample;
    }
};

pub const ColorSettings = struct {
    bg_color: dvui.Options.ColorOrName = .fromColor(.fromHex(tailwind.red500)),
};

pub const App = struct {
    alloc: Allocator = undefined,
    color_settings: ColorSettings = .{},

    sched: Sched = undefined,
    playback: Playback = .{},
    event_handler: EventHandler = undefined,
    running: bool = true,

    fast_event_handling: bool = true,
    /// fetches dvui events but caches them so that they are added with the next addAllEvents call
    /// call this regularly to handle events in between frames
    pub fn update(self: *App) void {
        if (self.fast_event_handling) {
            self.event_handler.check_events(&self.running);
        }
    }

    pub fn init(self: *App, alloc: Allocator, win: *dvui.Window, back: *dvui.backend) !void {
        self.alloc = alloc;
        try self.event_handler.init(alloc, 1024, win, back, 1024);
        try self.sched.init(alloc);
        try self.playback.init(alloc);
        const ex = AsyncExecutor.from_std_pool(&self.sched.pool);
        _ = ex;
    }

    pub fn deinit(self: *App) void {
        const alloc = self.alloc;
        self.playback.stop_stream();
        self.playback.deinit();
        self.sched.deinit(alloc);
        self.event_handler.deinit(alloc);
    }
};
