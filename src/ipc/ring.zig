//! The wire format of the host <-> renderer shared-memory region.
//!
//! Both processes map the same bytes and overlay `Header` on offset 0.
//! This struct IS the protocol: its field layout must be identical in
//! both processes, which is why it is `extern` (C-stable layout, no field
//! reordering). Changing any field's type or order is a protocol break
//! and must bump `version`.

const std = @import("std");

/// Total size of the shared region, header included. One page for now*;
/// The real display-list will be far larger, making header overhead moot.
pub const region_size = 4096;

/// Sanity marker the consumer checks validates first. "CARA": little-endian bytes.
pub const magic: u32 = 0x43415241; // "CARA"

/// Layout version. Bump on any change to `Header`'s shape so a mismatched
/// host/renderer pair fails loudly instead of misreading each other.
pub const version: u32 = 1;

/// Cache-line size on x86_64 and aarch64 -- The only targets Cara build for.
pub const cache_line = 64;

/// Pad identity
const pad_identity = cache_line - 2 * @sizeOf(u32);

/// Pad cursor
const pad_cursor = cache_line - @sizeOf(u32);

/// Fixed header at offset 0 of the region.
/// Three regions, each on its own cache-line:
///
///     - identity (magic, version): written once at init, read-only after.
///     - head: producer writer cursor - renderer writes, host reads.
///     - tail: consumer read cursor - host writes, renderer reads.
///
/// `head` and `tail` are isolated onto separate lines to avoid false sharing
/// between the two cores. This layout assumes the struct sits at the region
/// base, which it does: the base is page-aligned (4096) from mmap, so offset
/// 64 and 128 are genuinely cache-line-aligned addresses.
pub const Header = extern struct {
    /// --- identity line: write-once, read-only ---
    magic: u32,
    version: u32,
    _pad_identity: [pad_identity]u8 = std.mem.zeroes([pad_identity]u8),

    /// --- producer line: renderer writes, host reads ---
    head: u32,
    _pad_head: [pad_cursor]u8 = std.mem.zeroes([pad_cursor]u8),

    /// --- consumer line: host writes, renderer reads ---
    tail: u32,
    _pad_tail: [pad_cursor]u8 = std.mem.zeroes([pad_cursor]u8),
};

/// Byte offset where the payload area begins (immediately after the `Header`).
pub const payload_offset = @sizeOf(Header);

/// Usable payload bytes (region minus the header).
pub const payload_size = region_size - payload_offset;

comptime {
    // The layout IS the protocol - assert the offsets the doc comments promise.
    // If the pading math is ever wrong, this fails at compile time instead of
    // becoming silent cross-process corruption.
    std.debug.assert(@offsetOf(Header, "magic") == 0);
    std.debug.assert(@offsetOf(Header, "head") == cache_line);
    std.debug.assert(@offsetOf(Header, "tail") == 2 * cache_line);
    std.debug.assert(@sizeOf(Header) == 3 * cache_line);
}

/// On-wire prefix before every record's payload. 8 bytes so the payload that
/// follows is 8-aligned - the host @ptrCast draw commands in place later and
/// a misaligned @alignCast panics in safe builds
pub const RecordHeader = extern struct {
    len: u32, // payload byte count, or `skip_marker`
    tag: u32 = 0, // caller-defined record type; 0 = unset
};

pub const record_header_size = @sizeOf(RecordHeader); // == 8

/// A `len` no real record can carry -
/// (max real len < payload_size): "no payload" here.
/// Skip to the buffer base and read the real record there
pub const skip_marker: u32 = 0xFFFF_FFFF;

pub const PushError = error{ RingFull, RecordTooLarge };

comptime {
    std.debug.assert(record_header_size == 8);
    std.debug.assert(payload_size % 8 == 0); // every record stays 8-aligned
    std.debug.assert(payload_offset % cache_line == 0); // payload base is cache-aligned
}

/// Round `n` up to the next multiple of 8. Bit-trick over std.mem.alignForward
/// deliberately: no churny stdlib dependency for a comptime-known power of two.
fn padTo8(n: u32) u32 {
    return (n + 7) & ~@as(u32, 7);
}

/// Cursor bytes one record of `payload_len` consumes: header + padded payload
fn frameSize(payload_len: u32) u32 {
    return record_header_size + padTo8(payload_len);
}

// --- The Ring ---
//
// Single-producer (renderer, owns `head`) / single-consumer (host, owns `tail`)
// Synchronization granularity is the FRAME, not the record: a Writer appends
// many records and publishes once; a Reader snapshots once and drains many.
// One Release/Acquire pair per frame - matching the one FrameReady per frame.

pub const Ring = struct {
    header: *Header,
    payload: []u8, // exactly payload_size bytes - bounds-checked in safe builds

    /// Overlay a Ring onto a mapped region.
    /// The `align(cache_line)` requirement is the type-system proof
    /// that head@64 / tail@128 land on real cache-line boundaries - the false-sharing
    /// guarantee, enforced, not assumed.
    pub fn init(region: []align(cache_line) u8) Ring {
        std.debug.assert(region.len >= region_size);

        return .{
            .header = @ptrCast(region.ptr),
            .payload = region[payload_offset..][0..payload_size],
        };
    }

    pub fn writer(self: Ring) Writer {
        return .{
            .ring = self,
            .head = self.header.head, // producer owns head: plain load
            .tail = @atomicLoad(u32, &self.header.tail, .acquire),
        };
    }

    pub fn reader(self: Ring) ?Reader {
        const head = @atomicLoad(u32, &self.header.head, .acquire); // ONE Acquire/drain
        const tail = self.header.tail; // consumer owns tail: plain load

        if (head -% tail == 0) return null; // empty (unambiguous: monotonic cursors)

        return .{
            .ring = self,
            .head = head,
            .tail = tail,
        };
    }

    fn putHeader(self: Ring, idx: u32, h: RecordHeader) void {
        const p: *RecordHeader = @ptrCast(@alignCast(self.payload[idx..].ptr));
        p.* = h;
    }

    fn getHeader(self: Ring, idx: u32) RecordHeader {
        const p: *const RecordHeader = @ptrCast(@alignCast(self.payload[idx..].ptr));
        return p.*;
    }

    /// Producer view of one frame. Appends write payload bytes immediately but
    /// DO NOT Publish; `commit` publishes `head` exactly once
    pub const Writer = struct {
        ring: Ring,
        head: u32, // local working cursor - unpublished
        tail: u32, // last-known consumer tail (acquire snapshot)

        pub fn append(self: *Writer, tag: u32, record: []const u8) PushError!void {
            if (record.len > payload_size) return error.RecordTooLarge;

            const len: u32 = @intCast(record.len);
            const need = frameSize(len);

            if (need > payload_size) return error.RecordTooLarge;

            var idx = self.head % payload_size;
            const contiguous = payload_size - idx;
            const skip_pad: u32 = if (contiguous < need) contiguous else 0;
            const want = skip_pad + need;

            if (payload_size - (self.head -% self.tail) < want) {
                // Refresh the consumer's progress before declaring the ring full
                self.tail = @atomicLoad(u32, &self.ring.header.tail, .acquire);

                if (payload_size - (self.head -% self.tail) < want) return error.RingFull;
            }

            if (skip_pad != 0) {
                self.ring.putHeader(idx, .{ .len = skip_marker });
                idx = 0; // real record restarts at the buffer base
            }

            self.ring.putHeader(idx, .{ .len = len, .tag = tag });

            @memcpy(self.ring.payload[idx + record_header_size ..][0..len], record);

            self.head +%= want; // local only - not visible until commit
        }

        /// The one publish point: Release-store makes every appended byte visible
        pub fn commit(self: *Writer) void {
            @atomicStore(u32, &self.ring.header.head, self.head, .release);
        }
    };

    /// Consumer view of one frame: a consistent snapshot taken at `reader()`
    /// Drains records with no further atomics; `commit` publishes `tail` once
    pub const Reader = struct {
        ring: Ring,
        head: u32, // acquire snapshot - all bytes below this are visible
        tail: u32, // local working cursor

        pub const Record = struct {
            tag: u32,
            bytes: []const u8, // in-place view into the ring paylaod
        };

        /// Next record as an in-place view (no copy), or null when the frame's drained
        pub fn next(self: *Reader) ?Record {
            if (self.head -% self.tail == 0) return null;

            var idx = self.tail % payload_size;
            var step: u32 = 0;

            // skips the pad, and read the real record at the base
            if (self.ring.getHeader(idx).len == skip_marker) {
                step += payload_size - idx;
                idx = 0;
            }

            // Read len + tag together
            const hdr = self.ring.getHeader(idx);

            step += frameSize(hdr.len);
            self.tail +%= step;

            return .{ .tag = hdr.tag, .bytes = self.ring.payload[idx + record_header_size ..][0..hdr.len] };
        }

        /// Release the whole drained frame at once. Symmetric to Writer.commit
        pub fn commit(self: *Reader) void {
            @atomicStore(u32, &self.ring.header.tail, self.tail, .release);
        }
    };
};

// --- Tests ---
const testing = std.testing;

fn freshRing(backing: []align(cache_line) u8) Ring {
    const h: *Header = @ptrCast(backing.ptr);
    h.* = .{ .magic = magic, .version = version, .head = 0, .tail = 0 };
    return Ring.init(backing);
}

test "one record round-trips byte-for-byte, tag intact" {
    var backing: [region_size]u8 align(cache_line) = undefined;
    const r = freshRing(&backing);

    var w = r.writer();
    try w.append(42, "HELLO CARA");
    w.commit();

    var rd = r.reader() orelse return error.Empty;
    const rec = rd.next() orelse return error.Empty;
    try testing.expectEqual(@as(u32, 42), rec.tag);
    try testing.expectEqualSlices(u8, "HELLO CARA", rec.bytes);
    try testing.expect(rd.next() == null);
    rd.commit();
    try testing.expect(r.reader() == null); // fully drained
}

test "a frame of many records: tags and bytes both intact" {
    var backing: [region_size]u8 align(cache_line) = undefined;
    const r = freshRing(&backing);

    var w = r.writer();
    var i: u8 = 0;

    while (i < 32) : (i += 1) {
        // u8 widens to the u32 tag
        try w.append(i, &[_]u8{ i, i +% 1, i +% 2, i +% 3 });
    }

    w.commit(); // single Release-store for all 32 records

    var rd = r.reader() orelse return error.Empty; // single Acquire-load
    var seen: u8 = 0;

    while (rd.next()) |rec| : (seen += 1) {
        try testing.expectEqual(@as(u32, seen), rec.tag);
        try testing.expectEqualSlices(u8, &[_]u8{ seen, seen +% 1, seen +% 2, seen +% 3 }, rec.bytes);
    }

    rd.commit();

    try testing.expectEqual(@as(u8, 32), seen);
}

test "varying-length stream stays intact across many wraparounds" {
    var backing: [region_size]u8 align(cache_line) = undefined;
    const r = freshRing(&backing);

    var seed: u32 = 0x9E3779B9;
    var n: u32 = 0;
    while (n < 5000) : (n += 1) { // wraps the 3904B payload many times -> exercises skip_marker
        var buf: [200]u8 = undefined;
        const len = (seed % 200) + 1;
        for (0..len) |k| buf[k] = @truncate(seed +% @as(u32, @intCast(k)));

        var w = r.writer();
        try w.append(0, buf[0..len]);
        w.commit();

        var rd = r.reader() orelse return error.Empty;
        try testing.expectEqualSlices(u8, buf[0..len], rd.next().?.bytes);
        rd.commit();

        seed = seed *% 1664525 +% 1013904223; // LCG: deterministic, reproducible
    }
}

test "writer reports RingFull without clobbering unread bytes" {
    var backing: [region_size]u8 align(cache_line) = undefined;
    const r = freshRing(&backing);

    const rec = "0123456789ABCDEF"; // 16B payload -> 24B frame
    var w = r.writer();
    var pushed: u32 = 0;
    while (true) {
        w.append(0, rec) catch break;
        pushed += 1;
    }
    w.commit();
    try testing.expect(pushed > 0);

    var rd = r.reader() orelse return error.Empty;
    var drained: u32 = 0;
    while (rd.next()) |got| : (drained += 1) {
        try testing.expectEqualSlices(u8, rec, got.bytes);
    }
    rd.commit();
    try testing.expectEqual(pushed, drained); // nothing overwritten under backpressure
}

test "oversized record is rejected, not truncated" {
    var backing: [region_size]u8 align(cache_line) = undefined;
    const r = freshRing(&backing);
    var huge: [payload_size]u8 = undefined;
    var w = r.writer();
    try testing.expectError(error.RecordTooLarge, w.append(0, &huge));
}
