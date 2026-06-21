//! Glyph Shaping with a glyph cache enabled
//! turn a string + font size into positioned atlas-backed glyphs
//! Borrows the renderer's rasterizer, atlas packer, and atlas stream
//! Each (codepoint, font_px) is rasterized, packed, and streamed
//! Exactly Once, then re-used; this is the stream-once guarantee the
//! atlas stream needs so a repeated glyph never re-streams
//! The scene painter calls measure() (for layout) and shapeInto()
//! (for paint) per text run

const std = @import("std");
const draw = @import("draw");
const staging = @import("staging");
const atlas = @import("atlas.zig");
const raster = @import("raster.zig");

pub const max_run_glyphs = 256;

// Power of two, open-addressed, no eviction yet
const cache_cap = 4096;

pub const Size = struct {
    w: f32,
    h: f32,
};

const CachedGlyph = struct {
    atlas_x: u16 = 0,
    atlas_y: u16 = 0,

    // 0 = no bitmap (e.g. space); advance still applies
    atlas_w: u16 = 0,
    atlas_h: u16 = 0,

    bearing_x: i32 = 0,
    bearing_y: i32 = 0,

    advance: i32 = 0,
};

pub const Shaper = struct {
    rast: *raster.Rasterizer,
    packer: *atlas.Packer,
    stream: *staging.Producer,

    // rasterization scratch, sized for the largest glyph
    cov: [256 * 256]u8 = undefined,

    // Open-addressed cache keyed by (codepoint << 32 | font_px). key 0 = empty
    // no real glypoh hashes to 0 since font_px is always > 0
    keys: [cache_cap]u64 = std.mem.zeroes([cache_cap]u64),
    vals: [cache_cap]CachedGlyph = undefined,

    pub fn init(rast: *raster.Rasterizer, packer: *atlas.Packer, stream: *staging.Producer) Shaper {
        return .{
            .rast = rast,
            .packer = packer,
            .stream = stream,
        };
    }

    fn getCachedGlyph(self: *const Shaper, key: u64) ?CachedGlyph {
        var i: usize = @intCast(key & (cache_cap - 1));

        while (self.keys[i] != 0) : (i = (i + 1) & (cache_cap - 1)) {
            if (self.keys[i] == key) return self.vals[i];
        }

        return null;
    }

    fn putCachedGlyph(self: *Shaper, key: u64, val: CachedGlyph) void {
        var i: usize = @intCast(key & (cache_cap - 1));

        while (self.keys[i] != 0) : (i = (i + 1) & (cache_cap - 1)) {
            if (self.keys[i] == key) {
                self.vals[i] = val;
                return;
            }
        }

        self.keys[i] = key;
        self.vals[i] = val;
    }

    /// Cache-or-build one glyph
    /// On a miss it rasterizes, at the face's current size, which the
    /// caller must have set to font_px, packs an atlas cell and streams
    /// the coverage exactly once
    fn glyph(self: *Shaper, codepoint: u21, font_px: u32) !CachedGlyph {
        const key = (@as(u64, codepoint) << 32) | font_px;

        if (self.getCachedGlyph(key)) |cg| return cg;

        const g = try self.rast.rasterize(codepoint, &self.cov);

        // TODO: Remove after verifying cache
        std.debug.print("SHAPER: streamed glyph cp={d} size={d}\n", .{ codepoint, font_px });

        var cg = CachedGlyph{
            .bearing_x = g.bearing_x,
            .bearing_y = g.bearing_y,
            .advance = g.advance,
        };

        if (g.width != 0 and g.height != 0) {
            const cell = try self.packer.alloc(g.width, g.height);

            try self.stream.push(.{ .atlas_x = cell.x, .atlas_y = cell.y, .width = g.width, .height = g.height }, g.coverage);

            cg.atlas_x = @intCast(cell.x);
            cg.atlas_y = @intCast(cell.y);
            cg.atlas_w = @intCast(g.width);
            cg.atlas_h = @intCast(g.height);
        }

        self.putCachedGlyph(key, cg);

        return cg;
    }

    /// Append one DrawTextRun for `run`, pen starting at (pen_x, baseline_y)
    pub fn shapeInto(self: *Shaper, enc: *draw.Encoder, run: []const u8, font_px: u32, rgba: u32, pen_x: f32, baseline_y: f32) !void {
        try self.rast.setPixelSize(font_px);

        var glyphs: [max_run_glyphs]draw.PackedGlyph = undefined;
        var n: usize = 0;
        var x = pen_x;

        for (run) |ch| {
            if (n == glyphs.len) break;

            const cg = try self.glyph(ch, font_px);

            if (cg.atlas_w != 0 and cg.atlas_h != 0) {
                glyphs[n] = .{
                    .screen_x = x + @as(f32, @floatFromInt(cg.bearing_x)),
                    .screen_y = baseline_y - @as(f32, @floatFromInt(cg.bearing_y)),
                    .atlas_x = cg.atlas_x,
                    .atlas_y = cg.atlas_y,
                    .atlas_w = cg.atlas_w,
                    .atlas_h = cg.atlas_h,
                };

                n += 1;
            }

            x += @as(f32, @floatFromInt(cg.advance));
        }

        if (n > 0) try enc.textRun(rgba, glyphs[0..n]);
    }
};
