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
    _reserved: u32 = 0, // becomes the DrawCommand tag later
};

pub const record_header_size = @sizeOf(RecordHeader); // == 8

/// A `len` no real record can carry (max real len < payload_size): "no payload"
/// here - skip to the buffer base and read the real record there
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

        pub fn append(self: *Writer, record: []const u8) PushError!void {
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

            self.ring.putHeader(idx, .{ .len = len });

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

        /// Next record as an in-place view (no copy), or null when the frame's drained
        pub fn next(self: *Reader) ?[]const u8 {
            if (self.head -% self.tail == 0) return null;

            var idx = self.tail % payload_size;
            var step: u32 = 0;

            if (self.ring.getHeader(idx).len == skip_marker) {
                step += payload_size - idx; // skip the pad...
                idx = 0; // ... and read the real record at the base
            }

            const len = self.ring.getHeader(idx).len;
            step += frameSize(len);
            self.tail +%= step;

            return self.ring.payload[idx + record_header_size ..][0..len];
        }

        /// Release the whole drained frame at once. Symmetric to Writer.commit
        pub fn commit(self: *Reader) void {
            @atomicStore(u32, &self.ring.header.tail, self.tail, .release);
        }
    };
};
