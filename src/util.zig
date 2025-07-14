const std = @import("std");
const assert = std.debug.assert;
const expect = std.debug.expect;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const dvui = @import("dvui");

pub const rect = struct {
    pub const Direction = enum {
        top_down,
        left_to_right,
    };
    pub fn cut_ratio(r: dvui.Rect, d: Direction, ratio: f32) std.meta.Tuple(&.{ dvui.Rect, dvui.Rect }) {
        assert(ratio >= 0 and ratio <= 1);
        switch (d) {
            .top_down => {
                const h1 = r.h * ratio;
                const r1 = dvui.Rect{ .x = r.x, .y = r.y, .w = r.w, .h = h1 };
                const r2 = dvui.Rect{ .x = r.x, .y = r.y + h1, .w = r.w, .h = r.h - h1 };
                return .{ r1, r2 };
            },
            .left_to_right => {
                const w1 = r.w * ratio;
                const r1 = dvui.Rect{ .x = r.x, .y = r.y, .w = w1, .h = r.h };
                const r2 = dvui.Rect{ .x = r.x + w1, .y = r.y, .w = r.w - w1, .h = r.h };
                return .{ r1, r2 };
            },
        }
    }
    pub fn to_square(r: dvui.Rect, centered: bool) dvui.Rect {
        const m = @min(r.w, r.h);
        if (!centered) {
            return dvui.Rect{
                .w = m,
                .h = m,
                .x = r.x,
                .y = r.y,
            };
        } else {
            return dvui.Rect{
                .w = m,
                .h = m,
                .x = r.x + (r.w - m) * 0.5,
                .y = r.y + (r.h - m) * 0.5,
            };
        }
    }
};

pub inline fn alloc_init(alloc: Allocator, T: type, n: usize, init: T) ![]T {
    const p = try alloc.alloc(T, n);
    for (p) |*t| t.* = init;
    return p;
}
