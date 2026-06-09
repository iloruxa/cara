//! Host <-> Renderer control channel's wire format.
//!
//!     Small, Typed Messages
//! Over a Unix-domain stream socket.
//! Bulk per-frame data goes through the ring.
//! Only control crosses here - there is no third channel.
//!
//! Every message is an 8-byte MsgHeader (kind + payload length)
//! Followed by `len` payload bytes. Both processes overlay the
//! same `extern struct`, so the layout must be byte-identical.

const std = @import("std");

/// The v1 control-message catalog.
///
/// Wire value is MsgHeader.kind. Starts at 1 so a zeroed header
/// (kind 0) is detectably invalid. Non-exhaustive (`_`) so an
/// endpoint built before a newer message can skip an unknown
/// kind, not crash.
pub const MsgKind = enum(u32) {
    // renderer -> host: a display-list frame is committed to the ring
    frame_ready = 1,

    // host -> renderer: the frame was presented
    frame_done,

    // host -> renderer: an input, hit entity pre-resolved
    input_event,

    // LoadPage, Fetch, FetchResult, StorageOp, StorageResult,
    // A11yUpdate, Resize, SpawnRenderer, ProcessHealthCheck
    // Add as needed
    _,
};

/// Fixed 8-byte prefix on every control message.
/// `len` counts the payload bytes that follow.
///
/// - 0 when the message is a pure signal
pub const MsgHeader = extern struct {
    // A MsgKind value
    kind: u32,

    // Payload byte count following this header
    len: u32,
};

pub const msg_header_size = @sizeOf(MsgHeader); // == 8

pub const InputKind = enum(u32) {
    mouse_down = 1,
    _,
};

/// Carried as the payload after a MsgHeader{ .kind = input_event }
pub const InputEvent = extern struct {
    // an InputKind
    kind: u32,

    // bitfield (unused for now)
    modifiers: u32,

    // framebuffer-pixel coordinates
    x: f32,
    y: f32,

    // host-resolved hit entity (0 = background)
    entity: u32,
};

comptime {
    std.debug.assert(msg_header_size == 8);
    std.debug.assert(@alignOf(MsgHeader) <= 8);
}

// --- Tests ---
const testing = std.testing;

test "MsgHeader has a stable 8-byte layout" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(MsgHeader));
    try testing.expectEqual(@as(usize, 0), @offsetOf(MsgHeader, "kind"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(MsgHeader, "len"));

    // `kind` survives the round trip through its u32 wire form
    const wire = @intFromEnum(MsgKind.frame_ready);
    try testing.expectEqual(MsgKind.frame_ready, @as(MsgKind, @enumFromInt(wire)));
}
