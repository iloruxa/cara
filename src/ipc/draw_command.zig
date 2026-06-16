//! This is the sacred draw-command vocabulary
//! Its on-the-wire framing
//!
//! A frame slot carries the full display list as a sequence of length-prefixed
//! tagged commands. Each command on the wire is:
//!
//!     CommandHeader { tag, size } | payload (size bytes) | zero pad to 8
//!
//! `size` is the payload byte count; the record advances `8 + padTo8(size)`
//! So every payload begins 8-aligned and the host can `@ptrCast` it in place
//! with zero copies. Both processes overlay the exact same `extern` structs;
//! A layout change is a protocol break (bump `frame.version`)

const std = @import("std");

/// Tags starts at 1 so a zeroed header (tag 0) i detectably invalid.
/// Only `rect` exists today; `DrawTextRun`, `DrawImage`, and `Clip` join later
pub const DrawTag = enum(u32) {
    rect = 1,
    _,
};

/// Fill an axis-aligned rectangle.
/// Coordinates are f32 framebuffer pixels;
/// `rgba` packs the colour as 0xRRGGBBAA.
pub const DrawRect = extern struct { x: f32, y: f32, w: f32, h: f32, rgba: u32 };

/// Fixed 8-byte prefix on every command. `size` is the payload byte count (it excludes this header)
/// The whole record is `8 + padTo8(size)` bytes
pub const CommandHeader = extern struct {
    // a DrawTag
    tag: u32,

    // payload byte count
    size: u32,
};

// = 8
pub const command_header_size = @sizeOf(CommandHeader);

comptime {
    std.debug.assert(command_header_size == 8);
    std.debug.assert(@alignOf(CommandHeader) <= 8);
    // Must drop onto the ring's 8-aligned payload and be @ptrCast in place.
    std.debug.assert(@alignOf(DrawRect) <= 8);
}

/// Round `n` up to the next multiple of 8
pub fn padTo8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

pub const Overflow = error{Overflow};

/// Appends commands into a caller-owned byte buffer
/// The renderer's paint pass builds the display list here, then hands `bytes()`
/// to `frame.Producer.writeFrame`
pub const Encoder = struct {
    buf: []u8,
    len: usize = 0,

    /// Append one command: header, then payload, then zero pad to the next
    /// 8-byte boundary. Fails (writing nothing) if the buffer cannot hold it
    pub fn append(self: *Encoder, tag: DrawTag, payload: []const u8) Overflow!void {
        const record = command_header_size + padTo8(payload.len);

        if (record > self.buf.len - self.len) return error.Overflow;

        const hdr = CommandHeader{ .tag = @intFromEnum(tag), .size = @intCast(payload.len) };
        @memcpy(self.buf[self.len..][0..command_header_size], std.mem.asBytes(&hdr));

        var off = self.len + command_header_size;
        @memcpy(self.buf[off..][0..payload.len], payload);
        off += payload.len;

        const pad = padTo8(payload.len) - payload.len;

        if (pad != 0) @memset(self.buf[off..][0..pad], 0);

        self.len += record;
    }

    /// Convenience for a fixed-struct payload (e.g. a `DrawRect`).
    pub fn command(self: *Encoder, tag: DrawTag, value: anytype) Overflow!void {
        return self.append(tag, std.mem.asBytes(&value));
    }

    /// The encoded display list so far.
    pub fn bytes(self: *const Encoder) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Walks a command list in place (no copies). Bounds-checked: a truncated tail
/// ends iteration rather than reading past the buffer. Full validation of a
/// hostile producer is the trust boundary work; this is just the reader
pub const Iterator = struct {
    buf: []const u8,
    off: usize = 0,

    pub const Command = struct { tag: DrawTag, payload: []const u8 };

    pub fn next(self: *Iterator) ?Command {
        if (self.off + command_header_size > self.buf.len) return null;

        var hdr: CommandHeader = undefined;

        @memcpy(std.mem.asBytes(&hdr), self.buf[self.off..][0..command_header_size]);

        const payload_start = self.off + command_header_size;
        const payload_end = payload_start + hdr.size;

        // truncated tail
        if (payload_end > self.buf.len) return null;

        const payload = self.buf[payload_start..payload_end];
        self.off = payload_start + padTo8(hdr.size);
        return .{ .tag = @enumFromInt(hdr.tag), .payload = payload };
    }
};

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

test "encode then iterate: tags, payloads, and 8-aligned advances all intact" {
    var buf: [256]u8 align(8) = undefined;
    var enc = Encoder{ .buf = &buf };

    const rects = [_]DrawRect{
        .{ .x = 1, .y = 2, .w = 3, .h = 4, .rgba = 0x11223344 },
        .{ .x = 5, .y = 6, .w = 7, .h = 8, .rgba = 0xAABBCCDD },
        .{ .x = 9, .y = 10, .w = 11, .h = 12, .rgba = 0x0F0F0F0F },
    };
    for (rects) |rc| try enc.command(.rect, rc);

    // each DrawRect record: 8 header + padTo8(20)=24 -> 32 bytes
    try testing.expectEqual(@as(usize, 3 * 32), enc.bytes().len);

    var it = Iterator{ .buf = enc.bytes() };
    var seen: usize = 0;
    while (it.next()) |cmd| : (seen += 1) {
        try testing.expectEqual(DrawTag.rect, cmd.tag);
        try testing.expectEqual(@as(usize, @sizeOf(DrawRect)), cmd.payload.len);
        try testing.expect(@intFromPtr(cmd.payload.ptr) % 8 == 0); // 8-aligned -> @ptrCast is sound
        const got: *const DrawRect = @ptrCast(@alignCast(cmd.payload.ptr));
        try testing.expectEqual(rects[seen], got.*);
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "iterator stops cleanly on a truncated tail" {
    var buf: [64]u8 align(8) = undefined;
    var enc = Encoder{ .buf = &buf };
    try enc.command(.rect, DrawRect{ .x = 0, .y = 0, .w = 0, .h = 0, .rgba = 0 });

    var it = Iterator{ .buf = enc.bytes()[0 .. command_header_size + 4] };
    // header + partial body
    try testing.expect(it.next() == null);
}

test "encoder rejects a command that does not fit, writing nothing" {
    var small: [16]u8 align(8) = undefined; // needs 32 for one DrawRect record
    var enc = Encoder{ .buf = &small };
    try testing.expectError(error.Overflow, enc.command(.rect, DrawRect{ .x = 0, .y = 0, .w = 0, .h = 0, .rgba = 0 }));
    try testing.expectEqual(@as(usize, 0), enc.bytes().len);
}
