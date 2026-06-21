//! Paint: walk the laid-out scene and emit the display list
//! Box-like nodes emit a DrawRect from their background (when opaque)
//! text nodes emit a DrawTextRun per span via the shaper, positioned
//! at the span's laid-out box. Also provides the adapter that lets
//! layout measure text through the same shaper, so measure and paint
//! share one glyph cache. A glyph rasterized while measuring is
//! reused, not re-streamed, while painting

const std = @import("std");
const scene_mod = @import("scene.zig");
const layout = @import("layout.zig");
const shaper = @import("shaper.zig");
const draw = @import("draw");

const Scene = scene_mod.Scene;
const Entity = scene_mod.Entity;

/// Build a layout.TextMeasurer backed by the shaper
/// On a rasterization error it degrades to a zero-width line rather
/// than failing layout
pub fn measurer(sh: *shaper.Shaper) layout.TextMeasurer {
    return .{ .ctx = sh, .measureFn = measureText };
}

fn measureText(ctx: *anyopaque, text: []const u8, font_px: u32) layout.Size {
    const sh: *shaper.Shaper = @ptrCast(@alignCast(ctx));
    const sz = sh.measure(text, font_px) catch return .{ .w = 0, .h = @as(f32, @floatFromInt(font_px)) };

    return .{ .w = sz.w, .h = sz.h };
}

pub const Painter = struct {
    scene: *Scene,
    shaper: *shaper.Shaper,
    enc: *draw.Encoder,

    pub fn paint(self: *Painter, root: Entity) !void {
        try self.walk(root);
    }

    fn walk(self: *Painter, e: Entity) !void {
        const st = self.scene.style[e.index];
        const box = self.scene.box[e.index];

        switch (self.scene.kind[e.index]) {
            // emitted by the parent text node
            .span => return,
            .text => {
                // baseline approximated at 0.8 * font size below the line top
                // TODO: real ascent/descent from the face (refinement)
                const ascent = @as(f32, @floatFromInt(st.font_px)) * 0.8;
                var it = self.scene.children(e);

                while (it.next()) |sp| {
                    const sb = self.scene.box[sp.index];
                    const sd = self.scene.span[sp.index];

                    try self.shaper.shapeInto(self.enc, sd.text, st.font_px, st.fg, sb.x, sb.y + ascent);
                }
            },
            else => {
                // box / button / image / component / root: paint background, recurse

                // opaque alpha
                if ((st.bg & 0xFF) != 0) {
                    try self.enc.command(.rect, draw.DrawRect{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .rgba = st.bg });
                }

                var it = self.scene.children(e);

                while (it.next()) |child| try self.walk(child);
            },
        }
    }
};
