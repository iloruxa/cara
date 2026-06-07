//! This is the sacred draw-command vocabulary,
//! carried inside the ring records.
//!
//! A record's payload is exactly *one* command struct.
//! We figure out which one by checking the record's `tag`.
//!
//! Both processes have to overlay the exact same `extern struct`
//! onto these raw payload bytes.
//! If the memory layout isn't 100% byte-identical on both sides,
//! everything breaks silently.

const std = @import("std");

/// Starts at 1 so a zeroed/uninitialized record (tag 0) is
/// detectably invalid.
pub const DrawTag = enum(u32) {
    rect = 1,
    _,
};

/// Fill an axis-aligned rectangle.
/// Coordinates are f32 pixels;
/// rgba packs the colour as 0xRRGGBBAA.
pub const DrawRect = extern struct { x: f32, y: f32, w: f32, h: f32, rgba: u32 };

comptime {
    // Must drop onto the ring's 8-aligned payload and be @ptrCast in place.
    std.debug.assert(@alignOf(DrawRect) <= 8);
}

// --- Tests ---
const testing = std.testing;

test "DrawRect has a stable, ring-compatible layout" {
    // 4 * f32 + u32. No padding here
    try testing.expectEqual(@as(usize, 20), @sizeOf(DrawRect));

    try testing.expect(@alignOf(DrawRect) <= 8);

    // the tag survives the round trip through its u32 wire form
    const wire = @intFromEnum(DrawTag.rect);
    try testing.expectEqual(DrawTag.rect, @as(DrawTag, @enumFromInt(wire)));
}
