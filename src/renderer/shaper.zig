//! Glyph Shaping: turn a string + font size into positioned, atlas backed glyphs
//! Borrows (does not own) the renderer's rasterizer, atlas packer and atlas stream
//! For each character it rasterizes via FreeType, packs an atlas cell, streams the
//! coverage, and appends a PackedGlyph at the pen position using FreeType's bearings
//! then emits one DrawTextRun for the run. This is the resuable core the scene painter
//! will call per text node
//!
//! No glyph cache yet: every character is streamed on sight, so a repeated glyph is
//! streamed more than once.
//!
//! TODO: Dedupe

const std = @import("std");
const draw = @import("draw");
const staging = @import("staging");
const atlas = @import("atlas.zig");
const raster = @import("raster.zig");

pub const max_run_glyphs = 256;

pub const Shaper = struct {
    rast: *raster.Rasterizer,
    packer: *atlas.Packer,
    stream: *staging.Producer,

    // rasterization scratch, sized for the largest glyph
    cov: [256 * 256]u8 = undefined,

    pub fn init(rast: *raster.Rasterizer, packer: *atlas.Packer, stream: *staging.Producer) Shaper {
        return .{
            .rast = rast,
            .packer = packer,
            .stream = stream,
        };
    }

    /// Rasterize/pack/stream each char of `run` at `font_px`
    /// then append one DrawTextRun whose pen starts at
    /// (pen_x, baseline_y) in framebuffer pixels
    pub fn shapeInto(self: *Shaper, enc: *draw.Encoder, run: []const u8, font_px: u32, rgba: u32, pen_x: f32, baseline_y: f32) !void {
        try self.rast.setPixelSize(font_px);

        var glyphs: [max_run_glyphs]draw.PackedGlyph = undefined;
        var n: usize = 0;
        var x = pen_x;

        for (run) |ch| {
            if (n == glyphs.len) break;

            const g = try self.rast.rasterize(ch, &self.cov);

            if (g.width != 0 and g.height != 0) {
                const cell = try self.packer.alloc(g.width, g.height);

                try self.stream.push(.{ .atlas_x = cell.x, .atlas_y = cell.y, .width = g.width, .height = g.height }, g.coverage);

                glyphs[n] = .{
                    .screen_x = x + @as(f32, @floatFromInt(g.bearing_x)),
                    .screen_y = baseline_y - @as(f32, @floatFromInt(g.bearing_y)),
                    .atlas_x = @intCast(cell.x),
                    .atlas_y = @intCast(cell.y),
                    .atlas_w = @intCast(g.width),
                    .atlas_h = @intCast(g.height),
                };

                n += 1;
            }

            x += @as(f32, @floatFromInt(g.advance));
        }

        if (n > 0) try enc.textRun(rgba, glyphs[0..n]);
    }
};
