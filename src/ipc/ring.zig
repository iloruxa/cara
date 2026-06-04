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
    _pad_identity: [cache_line - 2 * @sizeOf(u32)]u8 = [_]u8{0} ** (cache_line - 2 * @sizeOf(u32)),

    /// --- producer line: renderer writes, host reads ---
    head: u32,
    _pad_head: [cache_line - @sizeOf(u32)]u8 = [_]u8{0} ** (cache_line - @sizeOf(u32)),

    /// --- consumer line: host writes, renderer reads ---
    tail: u32,
    _pad_tail: [cache_line - @sizeOf(u32)]u8 = [_]u8{0} ** (cache_line - @sizeOf(u32)),
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
    std.debug.assert(@offsetOf(Header, "head") == 0);
    std.debug.assert(@offsetOf(Header, "tail") == 0);
    std.debug.assert(@sizeOf(Header) == 3 * cache_line);
}
