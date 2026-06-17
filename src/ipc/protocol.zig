//! Host <-> Renderer control channel: the wire format.
//!
//! Small, Typed Messages over a Unix-domain stream socket.
//! Bulk per-frame data travels through the frame slots.
//! Only control crosses here - there is no third channel.
//!
//! Every message is an 8-byte `Envelope` (tag, flags, length, seq)
//! followed by `length` payload bytes. Both processes overlay the
//! same `extern struct`, so the layout must be byte-identical.

const std = @import("std");

/// The 13-message control catalog
///
/// Wire value is `Envelope.tag`.
/// Starts at 1 so a zeroed envelope (tag 0) is detectably invalid.
/// Non-exhaustive so an endpoint built before a newer message can
/// skip an unknown kind, not crash.
pub const Tag = enum(u32) {
    spawn_renderer,
    load_page,
    fetch,
    fetch_result,
    storage_op,
    storage_result,
    input_event,
    frame_ready,
    frame_tick,
    upload_done,
    a11y_update,
    resize,
    process_healthcheck,
    _,
};

/// Bits in `Envelope.flags`. On `frame_ready`, `frame_wants_tick`
/// asks the host to arm `FrameTick`; absent it, the host sends
/// no ticks (idle stays zero)
pub const flag_wants_tick: u16 = 1 << 0;

/// Fixed 12-byte prefix on every control message.
/// `length` counts the payload bytes that follow.
/// - 0 when the message is a pure signal
/// `seq` is monotonic per sender
pub const Envelope = extern struct {
    // A Tag
    tag: u16,

    // Tag-specific bits
    flags: u16,

    // Payload byte count following this header
    length: u32,

    // Per-sender monotonic sequence
    seq: u32,
};

// = 12 bytes
pub const envelope_size = @sizeOf(Envelope);

pub const InputKind = enum(u32) {
    mouse_down = 1,
    mouse_up,
    mouse_move,
    key_down,
    key_up,
    _,
};

/// Carried as the payload after a MsgHeader{ .kind = input_event }
pub const InputEvent = extern struct {
    // An InputKind
    kind: u32,

    //  Modifier bitfield (unused for now)
    modifiers: u32,

    // Framebuffer-pixel coordinates
    x: f32,
    y: f32,

    hit_entity: u32,
    frame_seq: u32,
};

comptime {
    std.debug.assert(envelope_size == 12);
    std.debug.assert(@alignOf(Envelope) <= 8);
    std.debug.assert(@sizeOf(InputEvent) == 24);
}

// --- Tests ---
const testing = std.testing;

test "Envelope has a stable 12-byte layout" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(Envelope));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Envelope, "tag"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(Envelope, "flags"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Envelope, "length"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Envelope, "seq"));

    const wire = @intFromEnum(Tag.frame_ready);
    try testing.expectEqual(Tag.frame_ready, @as(Tag, @enumFromInt(wire)));
}

test "InputEvent payload layout is stable" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
    try testing.expectEqual(@as(usize, 16), @offsetOf(InputEvent, "hit_entity"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(InputEvent, "frame_seq"));
}
