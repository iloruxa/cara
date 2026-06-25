//! The staging region's atlas stream
//!
//! An ordered, exactly-oncde SPSC byte stream carrying glyph coverage
//! bitmaps from the renderer (producer) to the host (consumer)
//!
//! This is the wrapping-cursor discipline retired from the frame path
//! living where it belongs: a skipped frame must never drop a glyph
//! bitmap, so bitmaps travel a stream, never a frame slot
//!
//! Two monotonic u32 cursors, each alone on its own cache line:
//!     atlas_head: the producer Release-advances it after writing an entry
//!     atlas_tail: the consumer Release-advances it after consuming one
//! used = head -% tail; the cursors are only ever combined with -% and
//! compared == / != (never < / >). `capacity` is a power of two,
//! so index = cursor & (capacity - 1) is exact and continuous across the
//! u32 wrap, and entries may straddle the buffer end (the byte copies
//! split around it).
//!
//! Unlike frame.zig, capacity is dynamic: the host sizes it from the
//! viewport (>= one frame's worst-case glyph additions, with slack) and
//! re-sizes on Resize, so it is a runtime value, not a comptime constant

const std = @import("std");

// "STAG" Little-endian
pub const magic: u32 = 0x47415453;
pub const version: u32 = 1;
pub const cache_line = 64;

/// Per-glyph entry header, followed by width*height bytes of 8-bit coverage
/// (alpha), tightly packed (row stride = width). 16 bytes
pub const AtlasEntry = extern struct {
    // placement in the atlas texture (top-left)
    atlas_x: u32,
    atlas_y: u32,
    width: u32,
    height: u32,
};

// after magic + version
const pad_after = cache_line - 2 * @sizeOf(u32);
const pad_cursor = cache_line - @sizeOf(u32);

/// Identity on line 0; the two hot cursors each isolated on their own line to
/// avoid false sharing (producer writes head + reads tail; consumer the reverse)
pub const Header = extern struct {
    magic: u32,
    version: u32,
    _pad0: [pad_after]u8 = std.mem.zeroes([pad_after]u8),

    atlas_head: u32,
    _pad1: [pad_cursor]u8 = std.mem.zeroes([pad_cursor]u8),

    atlas_tail: u32,
    _pad2: [pad_cursor]u8 = std.mem.zeroes([pad_cursor]u8),
};

// 3 cache lines
pub const header_size = @sizeOf(Header);

comptime {
    std.debug.assert(@offsetOf(Header, "magic") == 0);
    std.debug.assert(@offsetOf(Header, "atlas_head") == cache_line);
    std.debug.assert(@offsetOf(Header, "atlas_tail") == 2 * cache_line);
    std.debug.assert(header_size == 3 * cache_line);
    std.debug.assert(@sizeOf(AtlasEntry) == 16);
}

/// Region size for a stream of `capacity` bytes (capacity must be a power of two)
pub fn regionSize(capacity: u32) usize {
    std.debug.assert(std.math.isPowerOfTwo(capacity));
    return header_size + capacity;
}

/// Host: stamp identity + zero the cursors into a freshly mapped region
pub fn writeInitialHeader(region: []align(cache_line) u8) void {
    const h: *Header = @ptrCast(region.ptr);
    h.* = .{ .magic = magic, .version = version, .atlas_head = 0, .atlas_tail = 0 };
}

pub const ValidateError = error{ BadMagic, VersionMismatch, RegionTooSmall, CapacityNotPow2 };

/// Renderer: validate before trusting a byte. `capacity` is told to the renderer
/// over IPC (host-authoritative); this checks the mapping is big enough for it
pub fn validate(region: []align(cache_line) const u8, capacity: u32) ValidateError!void {
    if (!std.math.isPowerOfTwo(capacity)) return error.CapacityNotPow2;

    if (region.len < regionSize(capacity)) return error.RegionTooSmall;

    const h: *const Header = @ptrCast(region.ptr);

    if (h.magic != magic) return error.BadMagic;

    if (h.version != version) return error.VersionMismatch;
}

/// A mapped staging region split into its header and stream buffer
pub const Staging = struct {
    header: *Header,

    // exactly `capacity` bytes - power of two
    buffer: []u8,

    capacity: u32,

    pub fn init(region: []align(cache_line) u8, capacity: u32) Staging {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
        std.debug.assert(region.len >= regionSize(capacity));

        return .{
            .header = @ptrCast(region.ptr),
            .buffer = region[header_size..][0..capacity],
            .capacity = capacity,
        };
    }

    pub fn producer(self: Staging) Producer {
        return .{ .staging = self, .head = 0 };
    }

    pub fn consumer(self: Staging) Consumer {
        return .{ .staging = self, .tail = 0 };
    }

    // Straddle-aware copies: index masks into the ring, and a run
    // past the end wraps to offset 0. cap is a power of two,
    // so the mask is exact
    fn writeAt(self: Staging, cursor: u32, data: []const u8) void {
        const cap: usize = self.capacity;
        const start: usize = cursor & (self.capacity - 1);
        const first = @min(data.len, cap - start);

        @memcpy(self.buffer[start..][0..first], data[0..first]);

        if (data.len > first) @memcpy(self.buffer[0..][0 .. data.len - first], data[first..]);
    }

    fn readAt(self: Staging, cursor: u32, out: []u8) void {
        const cap: usize = self.capacity;
        const start: usize = cursor & (self.capacity - 1);
        const first = @min(out.len, cap - start);

        @memcpy(out[0..first], self.buffer[start..][0..first]);

        if (out.len > first) @memcpy(out[first..], self.buffer[0..][0 .. out.len - first]);
    }
};

pub const StreamFull = error{StreamFull};

/// Renderer side: append a glyph's coverage to the stream
pub const Producer = struct {
    staging: Staging,
    head: u32,

    pub fn push(self: *Producer, entry: AtlasEntry, coverage: []const u8) StreamFull!void {
        std.debug.assert(coverage.len == @as(usize, entry.width) * @as(usize, entry.height));

        const needed = @sizeOf(AtlasEntry) + coverage.len;

        const tail = @atomicLoad(u32, &self.staging.header.atlas_tail, .acquire);

        // magnitude in [0, capacity]
        const used = self.head -% tail;
        const free: usize = self.staging.capacity - used;

        // capacity must exceed one frame's worst case
        if (needed > free) return error.StreamFull;

        self.staging.writeAt(self.head, std.mem.asBytes(&entry));
        self.staging.writeAt(self.head +% @sizeOf(AtlasEntry), coverage);

        // Release: publishes every entry byte written above
        self.head +%= @intCast(needed);

        @atomicStore(u32, &self.staging.header.atlas_head, self.head, .release);
    }

    /// The head value a frame stamps as `atlas_head_required` (its drain floor)
    pub fn headCursor(self: Producer) u32 {
        return self.head;
    }
};

pub const PopError = error{CoverageBufferTooSmall};

/// Host side: drain glyphs in order. `coverage_out` must be atleast as large as
/// the biggest glyph (the host sizes it from the max atlas cell)
pub const Consumer = struct {
    staging: Staging,
    tail: u32,

    pub const Drained = struct { entry: AtlasEntry, coverage: []const u8 };

    pub fn pop(self: *Consumer, coverage_out: []u8) PopError!?Drained {
        const head = @atomicLoad(u32, &self.staging.header.atlas_head, .acquire);

        // head is renderer-writable
        // Clamp the published span to the buffer so a corrupt head can't
        // claim more than physically exists
        const avail = @min(head -% self.tail, self.staging.capacity);

        // No complete entry header published
        if (avail < @sizeOf(AtlasEntry)) return null;

        var entry: AtlasEntry = undefined;
        self.staging.readAt(self.tail, std.mem.asBytes(&entry));
        const len: usize = @as(usize, entry.width) * @as(usize, entry.height);

        // A garbage width/height must not drive an OOB read
        // The whole entry (header + coverage) must fit within what was actually published...
        if (@sizeOf(AtlasEntry) + len > avail) return null;

        // ... and within the caller's scratch buffer
        if (len > coverage_out.len) return error.CoverageBufferTooSmall;

        self.staging.readAt(self.tail +% @sizeOf(AtlasEntry), coverage_out[0..len]);

        self.tail +%= @sizeOf(AtlasEntry) + @as(u32, @intCast(len));

        @atomicStore(u32, &self.staging.header.atlas_tail, self.tail, .release);

        return .{
            .entry = entry,
            .coverage = coverage_out[0..len],
        };
    }

    // Bytes published but not yet drained (head -% tail)
    pub fn used(self: Consumer) u32 {
        return @min(@atomicLoad(u32, &self.staging.header.atlas_head, .acquire) -% self.tail, self.staging.capacity);
    }
};

// --- Tests ---
const testing = std.testing;
const test_cap: u32 = 64;
var test_region: [header_size + test_cap]u8 align(cache_line) = undefined;

fn fresh() Staging {
    writeInitialHeader(&test_region);
    return Staging.init(&test_region, test_cap);
}

fn fillCoverage(buf: []u8, seed: u8) void {
    for (buf, 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i));
}

test "header writes and validates" {
    writeInitialHeader(&test_region);
    try validate(&test_region, test_cap);
    try testing.expectError(error.CapacityNotPow2, validate(&test_region, 63));
    test_region[0] +%= 1;
    try testing.expectError(error.BadMagic, validate(&test_region, test_cap));
}

test "push one glyph, pop it back, then empty" {
    const s = fresh();
    var p = s.producer();
    var c = s.consumer();

    var cov: [4]u8 = undefined;
    fillCoverage(&cov, 0x10);
    try p.push(.{ .atlas_x = 7, .atlas_y = 9, .width = 4, .height = 1 }, &cov);

    var out: [256]u8 = undefined;
    const g = (try c.pop(&out)) orelse return error.NothingPopped;
    try testing.expectEqual(@as(u32, 7), g.entry.atlas_x);
    try testing.expectEqual(@as(u32, 9), g.entry.atlas_y);
    try testing.expectEqualSlices(u8, &cov, g.coverage);
    try testing.expect((try c.pop(&out)) == null);
}

test "FIFO order across several glyphs" {
    const s = fresh();
    var p = s.producer();
    var c = s.consumer();

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var cov: [4]u8 = undefined;
        fillCoverage(&cov, @truncate(i));
        try p.push(.{ .atlas_x = i, .atlas_y = 0, .width = 4, .height = 1 }, &cov);
    }
    var out: [256]u8 = undefined;
    i = 0;
    while (i < 3) : (i += 1) {
        const g = (try c.pop(&out)) orelse return error.NothingPopped;
        try testing.expectEqual(i, g.entry.atlas_x);
    }
    try testing.expect((try c.pop(&out)) == null);
}

test "an entry that straddles the buffer end round-trips byte for byte" {
    const s = fresh();
    var p = s.producer();
    var c = s.consumer();
    var out: [256]u8 = undefined;

    // Three 20-byte entries (16 header + 4 coverage) -> head at 60.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var cov: [4]u8 = undefined;
        fillCoverage(&cov, @truncate(i));
        try p.push(.{ .atlas_x = i, .atlas_y = 0, .width = 4, .height = 1 }, &cov);
    }
    // Drain two -> tail at 40, one entry left.
    _ = (try c.pop(&out)) orelse return error.NothingPopped;
    _ = (try c.pop(&out)) orelse return error.NothingPopped;

    // 8-wide glyph: its 16-byte header must straddle [60,64)+[0,12).
    var big: [8]u8 = undefined;
    fillCoverage(&big, 0xC0);
    try p.push(.{ .atlas_x = 0xDEAD, .atlas_y = 0xBEEF, .width = 8, .height = 1 }, &big);

    const left = (try c.pop(&out)) orelse return error.NothingPopped;
    try testing.expectEqual(@as(u32, 2), left.entry.atlas_x);

    const straddler = (try c.pop(&out)) orelse return error.NothingPopped;
    try testing.expectEqual(@as(u32, 0xDEAD), straddler.entry.atlas_x);
    try testing.expectEqual(@as(u32, 0xBEEF), straddler.entry.atlas_y);
    try testing.expectEqualSlices(u8, &big, straddler.coverage);
}

test "StreamFull when an entry does not fit; draining frees room" {
    const s = fresh();
    var p = s.producer();
    var c = s.consumer();
    var out: [256]u8 = undefined;

    var cov: [8]u8 = undefined; // 24-byte entries; two fit in 64, the third does not
    fillCoverage(&cov, 1);
    try p.push(.{ .atlas_x = 1, .atlas_y = 0, .width = 8, .height = 1 }, &cov);
    try p.push(.{ .atlas_x = 2, .atlas_y = 0, .width = 8, .height = 1 }, &cov);
    try testing.expectError(error.StreamFull, p.push(.{ .atlas_x = 3, .atlas_y = 0, .width = 8, .height = 1 }, &cov));

    _ = (try c.pop(&out)) orelse return error.NothingPopped; // frees 24 bytes
    try p.push(.{ .atlas_x = 3, .atlas_y = 0, .width = 8, .height = 1 }, &cov); // now fits
}

test "many push/pop cycles keep FIFO and used = head -% tail correct" {
    const s = fresh();
    var p = s.producer();
    var c = s.consumer();
    var out: [256]u8 = undefined;

    var seq: u32 = 0;
    while (seq < 10_000) : (seq += 1) {
        var cov: [6]u8 = undefined;
        fillCoverage(&cov, @truncate(seq));
        try p.push(.{ .atlas_x = seq, .atlas_y = 0, .width = 6, .height = 1 }, &cov);
        const g = (try c.pop(&out)) orelse return error.NothingPopped;
        try testing.expectEqual(seq, g.entry.atlas_x);
        try testing.expectEqual(@as(u32, 0), c.used());
    }
}

test "A garbage entry claiming more than published is rejected, no OOB" {
    const s = fresh();
    const entry = AtlasEntry{ .atlas_x = 0, .atlas_y = 0, .width = 0xFFFF, .height = 0xFFFF }; // len ~4.3e9
    s.writeAt(0, std.mem.asBytes(&entry));
    @atomicStore(u32, &s.header.atlas_head, test_cap, .release); // claim the whole buffer is published

    var c = s.consumer();
    var out: [256]u8 = undefined;
    const r = try c.pop(&out); // oversized entry rejected; the huge coverage is never read
    try testing.expect(r == null);
}

test "A corrupt head is clamped to capacity" {
    const s = fresh();
    @atomicStore(u32, &s.header.atlas_head, test_cap *% 4, .release); // far past the buffer
    var c = s.consumer();
    try testing.expect(c.used() <= test_cap);
}
