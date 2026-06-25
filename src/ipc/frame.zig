//! The Host <-> Renderer shared-memory transport: Three fixedd frame slots, latest-wins
//!
//! Both processes map the same bytes and overlay `Header` at offset 0.
//! The file IS the protocol: the shared structs are `extern`, and any layout
//! change must bump `version`. Geometry does NOT cross the boundary: It is the
//! comptime constants below, identical in both binaries, so the host never
//! reads a layout-defining value from renderer-writable memory. The only
//! in-band identity is the magic + version stamp the renderer checks on map
//! (A binary skew guard)

const std = @import("std");

/// --- "CARA" : Little-Endian ---
pub const magic: u32 = 0x43415241;

/// Layout version
/// NOTE: Bump on any change to `Header`. `FrameHeader`, `Latest`, or the
/// geometry constants, so a mismatched host/renderer pair fails loud
pub const version: u32 = 1;

/// Cache-line size on x86_64 and aarch64
pub const cache_line = 64;

/// Triple-buffer: fixed at three, the minimum that keeps producer and consumer
/// from ever aliasing a slot
pub const slot_count = 3;

/// Slots begin one page in: `Header` occupies the first two cache lines
pub const slots_offset = 4096;

/// Pre-slot size
/// Real text pages overflow 64 KiB immediately, so 256 KiB is the floor.
/// Comptime never carried in the region
pub const slot_size = 256 * 1024;

/// Total shared-region size: one header page + three slots
pub const region_size = slots_offset + slot_count * slot_size;

/// The published-frame word: one u32 so a single atomic exchange publishes
/// (or takes) a frame. Bits, LSB first: slot(2), dirty(1), generation(29)
/// The dirty bit alone carries latest-wins correctness; generation guarantees
/// the word changes on every publish (a future Linux futex-wait needs that)
/// and makes frame tracing free
pub const Latest = packed struct(u32) {
    slot: u2,
    dirty: bool,
    generation: u29,
};

/// Initial slot partition
/// Pinned so the two processes agree without a handshake: three distinct slots
pub const init_back_slot: u2 = 0;
pub const init_latest_slot: u2 = 1;
pub const init_front_slot: u2 = 2;

// magic + version
const pad_identity = cache_line - 2 * @sizeOf(u32);
const pad_latest = cache_line - @sizeOf(u32);

/// Fixed header at offset 0. Two cache lines: identity (write-once) and
/// the one hot atomic, `latest`, alone on its own line to avoid false sharing.
/// No geometry here by design
pub const Header = extern struct {
    magic: u32,
    version: u32,
    _pad_identity: [pad_identity]u8 = std.mem.zeroes([pad_identity]u8),

    latest: u32,
    _pad_latest: [pad_latest]u8 = std.mem.zeroes([pad_latest]u8),
};

/// Per-slot prefix, followed by `damage_rect_count` `DamageRect`s, then
/// `command_bytes` of display list. `atlas_head_required` is the atlas-stream
/// floor (0 until that stream exists). 24 bytes, so commands stay 8-aligned
pub const FrameHeader = extern struct {
    seq: u32,
    viewport_w: u32,
    viewport_h: u32,
    atlas_head_required: u32 = 0,
    damage_rect_count: u32 = 0,
    command_bytes: u32 = 0,
};

/// A damage rectangle is framebuffer pixels. 16-bytes, 8-aligned
pub const DamageRect = extern struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

comptime {
    std.debug.assert(@offsetOf(Header, "magic") == 0);
    std.debug.assert(@offsetOf(Header, "latest") == cache_line);
    std.debug.assert(@sizeOf(Header) == 2 * cache_line);
    std.debug.assert(@sizeOf(Latest) == @sizeOf(u32));
    std.debug.assert(slots_offset % cache_line == 0);
    std.debug.assert(slots_offset >= @sizeOf(Header));
    std.debug.assert(slots_offset % 8 == 0);
    std.debug.assert(@sizeOf(FrameHeader) == 24 and @sizeOf(FrameHeader) % 8 == 0);
    std.debug.assert(@sizeOf(DamageRect) % 8 == 0);

    // Pin the bit layout of `latest`
    std.debug.assert(@as(u32, @bitCast(Latest{ .slot = 1, .dirty = false, .generation = 0 })) == 1);
    std.debug.assert(@as(u32, @bitCast(Latest{ .slot = 0, .dirty = true, .generation = 0 })) == 4);

    // Initial partition: three distinct, in-range slots
    std.debug.assert(init_back_slot != init_latest_slot and init_back_slot != init_front_slot and init_latest_slot != init_front_slot);
    std.debug.assert(init_back_slot < slot_count and init_latest_slot < slot_count and init_front_slot < slot_count);
}

/// Host: write the initial header into a freshly mapped region. Call once, before spawning
/// the renderer
pub fn writeInitialHeader(region: []align(cache_line) u8) void {
    std.debug.assert(region.len >= region_size);

    const h: *Header = @ptrCast(region.ptr);

    h.* = .{
        .magic = magic,
        .version = version,
        .latest = @as(u32, @bitCast(Latest{ .slot = init_latest_slot, .dirty = false, .generation = 0 })),
    };
}

pub const ValidateError = error{ BadMagic, VersionMismatch, RegionTooSmall };

/// REnderer: validate the host-created region before trusting a byte
/// Geometry is comptime, so only the skew stamp is checked in-band
pub fn validate(region: []align(cache_line) const u8) ValidateError!void {
    if (region.len < region_size) return error.RegionTooSmall;

    const h: *const Header = @ptrCast(region.ptr);

    if (h.magic != magic) return error.BadMagic;
    if (h.version != version) return error.VersionMismatch;
}

pub const FrameTooLarge = error{FrameTooLarge};

/// A parsed view of one slot: header plus in-place slices. No Copies.
pub const Frame = struct {
    // copied out of the slot
    // never re-read renderer-writable memory
    header: FrameHeader,
    damage: []const DamageRect,
    commands: []const u8,
};

/// Overlay onto a mapped region. `align(cache_line)` is the type-system proof
/// that `latest` at offset 64 lands on a real cache-line boundary
pub const Frames = struct {
    header: *Header,
    region: []align(cache_line) u8,

    pub fn init(region: []align(cache_line) u8) Frames {
        std.debug.assert(region.len >= region_size);
        return .{ .header = @ptrCast(region.ptr), .region = region };
    }

    fn slotBytes(self: Frames, idx: u2) []u8 {
        const start = slots_offset + @as(usize, idx) * slot_size;
        return self.region[start..][0..slot_size];
    }

    pub fn producer(self: Frames) Producer {
        return .{ .frames = self, .back = init_back_slot, .gen = 0 };
    }

    pub fn consumer(self: Frames) Consumer {
        return .{ .frames = self, .front = init_front_slot };
    }
};

/// Producer (renderer)
/// Writes a complete frame into a private back slot, then publishes with one acq_rel
/// exchange. Never blocks: no backpressure here
pub const Producer = struct {
    frames: Frames,
    back: u2,
    gen: u29,

    /// Lay a full frame into the back slot
    /// `damage_rect_count`/`command_bytes` are overwritten to match the slices,
    /// so the header cannot lie
    pub fn writeFrame(self: *Producer, fh: FrameHeader, damage: []const DamageRect, commands: []const u8) FrameTooLarge!void {
        const s = self.frames.slotBytes(self.back);
        const dmg_bytes = damage.len * @sizeOf(DamageRect);
        const total = @sizeOf(FrameHeader) + dmg_bytes + commands.len;

        if (total > s.len) return error.FrameTooLarge;

        var hdr = fh;
        hdr.damage_rect_count = @intCast(damage.len);
        hdr.command_bytes = @intCast(commands.len);

        const hp: *FrameHeader = @ptrCast(@alignCast(s.ptr));
        hp.* = hdr;

        var off: usize = @sizeOf(FrameHeader);

        if (dmg_bytes != 0) {
            const dsrc: [*]const u8 = @ptrCast(damage.ptr);
            @memcpy(s[off..][0..dmg_bytes], dsrc[0..dmg_bytes]);

            off += dmg_bytes;
        }

        if (commands.len != 0) @memcpy(s[off..][0..commands.len], commands);
    }

    /// The one publish point: a single acq_rel exchange swaps the back slot into `latest`
    /// (dirty=1, gen bumped). The release half publishes every frame byte written before it.
    /// The value handed back becomes the next back slot
    pub fn publish(self: *Producer) void {
        self.gen +%= 1;
        const next = Latest{ .slot = self.back, .dirty = true, .generation = self.gen };
        const prev: Latest = @bitCast(@atomicRmw(u32, &self.frames.header.latest, .Xchg, @as(u32, @bitCast(next)), .acq_rel));
        self.back = prev.slot;
    }
};

/// Consumer (host)
/// Holds one front slot until it takes a newer one, so expose and resie can re-encode the last frame
pub const Consumer = struct {
    frames: Frames,
    front: u2,

    /// Check, then exchange.
    /// Acquire-load `latest`; if not dirty, nothing was published since the last take, so return null
    /// (coalesced FrameReady wakeups are normal). Otherwise one acq_rel exchange swaps the front slot
    /// in (dirty=0) and hands back the newest published slot
    pub fn take(self: *Consumer) ?[]const u8 {
        const cur: Latest = @bitCast(@atomicLoad(u32, &self.frames.header.latest, .acquire));

        if (!cur.dirty) return null;

        const next = Latest{ .slot = self.front, .dirty = false, .generation = cur.generation };
        const got: Latest = @bitCast(@atomicRmw(u32, &self.frames.header.latest, .Xchg, @as(u32, @bitCast(next)), .acq_rel));

        // `latest` is renderer-writable
        // clamp the slot so a corrupt index can never index pas the slots
        // NOTE: This is the one place renderer-controlled index enters
        const slot: u2 = @min(got.slot, slot_count - 1);

        self.front = slot;

        return self.frames.slotBytes(slot);
    }
};

/// Parse a taken slot into header + in-place damage/command slices
/// The slot is renderer-writable: the header is copied once (never re-read)
/// and every renderer-supplied count is bounded to the slot, so a hostile or
/// garbage header can never slice out of bounds.
/// Worst case is garbage pixels, never an OOB read
pub fn parse(slot_bytes: []const u8) Frame {
    const header_size = @sizeOf(FrameHeader);

    if (slot_bytes.len < header_size) {
        return .{ .header = .{ .seq = 0, .viewport_w = 0, .viewport_h = 0 }, .damage = &.{}, .commands = &.{} };
    }

    const hp: *const FrameHeader = @ptrCast(@alignCast(slot_bytes.ptr));

    // read once; do not re-dereference renderer-writable memory
    const hdr = hp.*;

    const after_header = slot_bytes.len - header_size;
    const max_damage = after_header / @sizeOf(DamageRect);
    const dmg_count = @min(@as(usize, hdr.damage_rect_count), max_damage);

    var off: usize = header_size;
    const dptr: [*]const DamageRect = @ptrCast(@alignCast(slot_bytes[off..].ptr));
    const damage = dptr[0..dmg_count];

    off += dmg_count * @sizeOf(DamageRect);

    const remaining = slot_bytes.len - off;
    const cmd_len = @min(@as(usize, hdr.command_bytes), remaining);
    const commands = slot_bytes[off..][0..cmd_len];

    return .{ .header = hdr, .damage = damage, .commands = commands };
}

// --- Tests ---
const testing = std.testing;

// The region lives in static storage, not on the stack: 256 KiB slots make it
// ~772 KiB. Tests run sequentially and re-init it each time.
var test_region_buf: [region_size]u8 align(cache_line) = undefined;

fn freshFrames() Frames {
    writeInitialHeader(&test_region_buf);
    return Frames.init(&test_region_buf);
}

test "header writes and validates; geometry is comptime" {
    writeInitialHeader(&test_region_buf);
    try validate(&test_region_buf);
    test_region_buf[0] +%= 1; // corrupt magic
    try testing.expectError(error.BadMagic, validate(&test_region_buf));
}

test "single frame round-trips: header, damage, commands" {
    const f = freshFrames();
    var p = f.producer();
    var c = f.consumer();
    const dmg = [_]DamageRect{ .{ .x = 1, .y = 2, .w = 3, .h = 4 }, .{ .x = 5, .y = 6, .w = 7, .h = 8 } };
    try p.writeFrame(.{ .seq = 7, .viewport_w = 800, .viewport_h = 600 }, &dmg, "HELLO CARA");
    p.publish();
    const fr = parse(c.take() orelse return error.NothingTaken);
    try testing.expectEqual(@as(u32, 7), fr.header.seq);
    try testing.expectEqual(@as(u32, 2), fr.header.damage_rect_count);
    try testing.expectEqualSlices(u8, "HELLO CARA", fr.commands);
    try testing.expectEqual(@as(u32, 8), fr.damage[1].h);
    try testing.expect(c.take() == null);
}

test "latest-wins: three publishes, one take yields the newest" {
    const f = freshFrames();
    var p = f.producer();
    var c = f.consumer();
    var seq: u32 = 1;
    while (seq <= 3) : (seq += 1) {
        try p.writeFrame(.{ .seq = seq, .viewport_w = 0, .viewport_h = 0 }, &.{}, "");
        p.publish();
    }
    try testing.expectEqual(@as(u32, 3), parse(c.take() orelse return error.NothingTaken).header.seq);
    try testing.expect(c.take() == null);
}

test "coalesced wakeups: take returns null when nothing new" {
    const f = freshFrames();
    var p = f.producer();
    var c = f.consumer();
    try testing.expect(c.take() == null);
    try p.writeFrame(.{ .seq = 42, .viewport_w = 0, .viewport_h = 0 }, &.{}, "");
    p.publish();
    try testing.expectEqual(@as(u32, 42), parse(c.take() orelse return error.NothingTaken).header.seq);
    try testing.expect(c.take() == null);
    try testing.expect(c.take() == null);
}

test "triple-buffer partition stays distinct under interleaving" {
    const f = freshFrames();
    var p = f.producer();
    var c = f.consumer();
    var seed: u32 = 0x1234567;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223;
        if (seed & 1 == 0) {
            try p.writeFrame(.{ .seq = i, .viewport_w = 0, .viewport_h = 0 }, &.{}, "");
            p.publish();
        } else _ = c.take();
        const lat: Latest = @bitCast(@atomicLoad(u32, &f.header.latest, .acquire));
        try testing.expect(p.back != lat.slot and p.back != c.front and
            lat.slot != c.front);
    }
}

test "producer never blocks: many publishes, no consumer" {
    const f = freshFrames();
    var p = f.producer();
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        try p.writeFrame(.{ .seq = i, .viewport_w = 0, .viewport_h = 0 }, &.{}, "");
        p.publish();
    }
    var c = f.consumer();
    try testing.expectEqual(@as(u32, 499), parse(c.take() orelse return error.NothingTaken).header.seq);
}

test "writeFrame rejects a frame larger than the slot" {
    const f = freshFrames();
    var p = f.producer();
    const big = test_region_buf[0..slot_size]; // len == slot_size, so header + this overflows
    try testing.expectError(error.FrameTooLarge, p.writeFrame(.{ .seq = 0, .viewport_w = 0, .viewport_h = 0 }, &.{}, big));
}

test "a corrupt latest slot index never reads out of bounds" {
    const f = freshFrames();
    const bad = Latest{ .slot = 3, .dirty = true, .generation = 1 }; // slot 3: only 0..2 exist
    @atomicStore(u32, &f.header.latest, @as(u32, @bitCast(bad)), .release);
    var c = f.consumer();
    const slot = c.take() orelse return error.NothingTaken;
    try testing.expectEqual(@as(usize, slot_size), slot.len); // in-bounds, no OOB
}

test "oversized header counts are clamped to the slot" {
    var buf: [1024]u8 align(8) = std.mem.zeroes([1024]u8);
    const hp: *FrameHeader = @ptrCast(@alignCast(&buf));
    hp.damage_rect_count = 0xFFFF_FFFF;
    hp.command_bytes = 0xFFFF_FFFF;

    const fr = parse(&buf);
    try testing.expect(fr.commands.len <= buf.len);
    try testing.expect(fr.damage.len * @sizeOf(DamageRect) <= buf.len);
    for (fr.commands) |_| {} // touch every byte; must not run past the slot
}
