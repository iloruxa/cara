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
/// Only `rect` & `text_run` exists today; `DrawImage`, and `Clip` join later
pub const DrawTag = enum(u32) {
    rect = 1,
    text_run = 2,
    _,
};

/// Fill an axis-aligned rectangle.
/// Coordinates are f32 framebuffer pixels;
/// `rgba` packs the colour as 0xRRGGBBAA.
pub const DrawRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    rgba: u32,
    entity: u32 = 0,
};

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

/// Heaader of a DrawTextRun command's payload, followed by `glyph_count`
/// PackedGlyphs. One color per run
pub const TextRunHeader = extern struct {
    // 0xRRGGBBAA, applied to every glyph in the run
    rgba: u32,

    glyph_count: u32,

    entity: u32,
};

/// One positioned glyph. The host draws an atlas_w x atlas_h quad
/// at (screen_x, screen_y) framebuffer px, sampling atlas texels
/// [atlas_x, atlas_x + atlas_y) x [atlas_y, atlas_y + atlas_h]
/// Quad size equals the atlas cell because the glyph was rasterized
/// at its target pixel size.
/// 16 Bytes
pub const PackedGlyph = extern struct {
    screen_x: f32,
    screen_y: f32,
    atlas_x: u16,
    atlas_y: u16,
    atlas_w: u16,
    atlas_h: u16,
};

comptime {
    std.debug.assert(@sizeOf(TextRunHeader) == 12);
    std.debug.assert(@sizeOf(PackedGlyph) == 16);
    std.debug.assert(@alignOf(TextRunHeader) <= 8 and @alignOf(PackedGlyph) <= 8);
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

    /// Append a packed text run: a TextRunHeader then the glyphs, as one command
    /// The whole run is a single DrawTextRun, never one command per glyph
    pub fn textRun(self: *Encoder, rgba: u32, entity: u32, glyphs: []const PackedGlyph) Overflow!void {
        const glyph_bytes = std.mem.sliceAsBytes(glyphs);
        const payload_len = @sizeOf(TextRunHeader) + glyph_bytes.len;
        const record = command_header_size + padTo8(payload_len);

        if (record > self.buf.len - self.len) return error.Overflow;

        const cmd = CommandHeader{ .tag = @intFromEnum(DrawTag.text_run), .size = @intCast(payload_len) };

        @memcpy(self.buf[self.len..][0..command_header_size], std.mem.asBytes(&cmd));

        var off = self.len + command_header_size;

        const trh = TextRunHeader{ .rgba = rgba, .glyph_count = @intCast(glyphs.len), .entity = entity };

        @memcpy(self.buf[off..][0..@sizeOf(TextRunHeader)], std.mem.asBytes(&trh));

        off += @sizeOf(TextRunHeader);

        @memcpy(self.buf[off..][0..glyph_bytes.len], glyph_bytes);

        off += glyph_bytes.len;

        // always 0 (8 + 16n), kept for symmetry
        const pad = padTo8(payload_len) - payload_len;

        if (pad != 0) @memset(self.buf[off..][0..pad], 0);

        self.len += record;
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

pub const TextRun = struct {
    rgba: u32,
    entity: u32,
    glyphs: []const PackedGlyph,
};

/// Decode a DrawTextRun command's payload in place (no copy)
/// Returns null if the payload is too short for its declared glyph_count
/// The payload begins 8-aligned in a slot so the casts are sound there
pub fn parseTextRun(payload: []const u8) ?TextRun {
    if (payload.len < @sizeOf(TextRunHeader)) return null;

    const trh: *const TextRunHeader = @ptrCast(@alignCast(payload.ptr));
    const rest = payload[@sizeOf(TextRunHeader)..];
    const need = @as(usize, trh.glyph_count) * @sizeOf(PackedGlyph);

    if (rest.len < need) return null;

    const glyphs: []const PackedGlyph = @as([*]const PackedGlyph, @ptrCast(@alignCast(rest.ptr)))[0..trh.glyph_count];

    return .{ .rgba = trh.rgba, .entity = trh.entity, .glyphs = glyphs };
}

// --- Tests ---
const testing = std.testing;

test "DrawRect has a stable, ring-compatible layout" {
    // 4 * f32 + u32. No padding here
    try testing.expectEqual(@as(usize, 24), @sizeOf(DrawRect));

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

test "PackedGlyph and TextRunHeader have stable layouts" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(TextRunHeader));
    try testing.expectEqual(@as(usize, 16), @sizeOf(PackedGlyph));
}

test "encode a text run, iterate and parse it back" {
    var buf: [256]u8 align(8) = undefined;
    var enc = Encoder{ .buf = &buf };

    const glyphs = [_]PackedGlyph{
        .{ .screen_x = 10, .screen_y = 20, .atlas_x = 1, .atlas_y = 2, .atlas_w = 8, .atlas_h = 12 },
        .{ .screen_x = 18, .screen_y = 20, .atlas_x = 9, .atlas_y = 2, .atlas_w = 7, .atlas_h = 12 },
    };
    try enc.textRun(0x3B82F6FF, 7, &glyphs);

    var it = Iterator{ .buf = enc.bytes() };
    const cmd = it.next() orelse return error.NoCommand;
    try testing.expectEqual(DrawTag.text_run, cmd.tag);

    const run = parseTextRun(cmd.payload) orelse return error.BadRun;
    try testing.expectEqual(@as(u32, 0x3B82F6FF), run.rgba);
    try testing.expectEqual(@as(u32, 7), run.entity);
    try testing.expectEqual(@as(usize, 2), run.glyphs.len);
    try testing.expectEqual(glyphs[1].atlas_x, run.glyphs[1].atlas_x);
    try testing.expectEqual(glyphs[0].screen_x, run.glyphs[0].screen_x);
    try testing.expect(it.next() == null);
}

test "a rect and a text run coexist in one command stream" {
    var buf: [256]u8 align(8) = undefined;
    var enc = Encoder{ .buf = &buf };
    try enc.command(.rect, DrawRect{ .x = 0, .y = 0, .w = 4, .h = 4, .rgba = 0xFF0000FF });
    const glyphs = [_]PackedGlyph{.{ .screen_x = 1, .screen_y = 1, .atlas_x = 0, .atlas_y = 0, .atlas_w = 5, .atlas_h = 9 }};
    try enc.textRun(0x00FF00FF, 0, &glyphs);

    var it = Iterator{ .buf = enc.bytes() };
    try testing.expectEqual(DrawTag.rect, (it.next() orelse return error.NoCommand).tag);
    const c2 = it.next() orelse return error.NoCommand;
    try testing.expectEqual(DrawTag.text_run, c2.tag);
    try testing.expectEqual(@as(usize, 1), (parseTextRun(c2.payload) orelse
        return error.BadRun).glyphs.len);
    try testing.expect(it.next() == null);
}

test "parseTextRun rejects a truncated payload" {
    var buf: [256]u8 align(8) = undefined;
    var enc = Encoder{ .buf = &buf };
    const glyphs = [_]PackedGlyph{.{ .screen_x = 0, .screen_y = 0, .atlas_x = 0, .atlas_y = 0, .atlas_w = 1, .atlas_h = 1 }};
    try enc.textRun(0, 0, &glyphs);

    var it = Iterator{ .buf = enc.bytes() };
    const cmd = it.next() orelse return error.NoCommand;
    try testing.expect(parseTextRun(cmd.payload[0 .. cmd.payload.len - 8]) == null); // claims 1 glyph, body short
}

test "fuzz: iterator and parseTextRun survive arbitrary command bytes (5.17)" {
    var prng = std.Random.DefaultPrng.init(0xD4A0_1158);
    const rng = prng.random();

    // 8-aligned like a slot's command area (command_header_size == 8) so payloads
    // land aligned and parseTextRun's @alignCasts are sound: this tests the bounds
    // logic, not a spurious alignment panic.
    var buf: [4096]u8 align(8) = undefined;

    var sink: u64 = 0;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        rng.bytes(&buf);

        var it = Iterator{ .buf = &buf };
        while (it.next()) |cmd| {
            sink +%= cmd.payload.len; // payload is a checked sub-slice
            // glyphs come from a raw pointer (unchecked), so read them to prove
            // glyph_count was bounded against the payload.
            if (parseTextRun(cmd.payload)) |run| {
                for (std.mem.sliceAsBytes(run.glyphs)) |b| sink +%= b;
            }
        }
    }
    std.mem.doNotOptimizeAway(sink);
}

test "parseTextRun bounds glyph_count at the payload edge (5.17)" {
    const H = @sizeOf(TextRunHeader);
    const G = @sizeOf(PackedGlyph);
    var buf: [H + 4 * G]u8 align(8) = undefined;
    @memset(&buf, 0);
    const hdr: *TextRunHeader = @ptrCast(@alignCast(&buf));

    hdr.glyph_count = 4; // exactly fills the trailing space
    try testing.expect(parseTextRun(&buf).?.glyphs.len == 4);

    hdr.glyph_count = 5; // one past the edge -> rejected, no OOB slice
    try testing.expect(parseTextRun(&buf) == null);

    hdr.glyph_count = 0xFFFF_FFFF; // absurd (no u32*size overflow on 64-bit usize)
    try testing.expect(parseTextRun(&buf) == null);

    try testing.expect(parseTextRun(buf[0 .. H - 1]) == null); // truncated header
}
