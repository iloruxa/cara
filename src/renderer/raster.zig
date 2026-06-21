//! FreeType-backed glyph rasterizer (renderer-owned)
//! Holds the FT_Library and FT_Face; rasterizes a codepoint at the
//! configured pixel size to 8-bit coverage (tightly packed, stride = width)
//! plus the metrics layout needs.
//! The atlas packer turns (width, height) into a position; the staging atlas
//! stream carries the coverage to the host.
//!
//! FreeType is a C wall, spoken to through its C API at this seam;

const std = @import("std");
const ft = @import("freetype");

pub const Error = error{ Init, LoadFace, SetSize, LoadGlyph };

/// A rasterized glyph, `coverage` is width*height bytes of 8-bit alpha and
/// points into the caller's `out` buffer, so it is valid only until the next
/// rasterize() reuses that buffer
pub const Glyph = struct {
    width: u32,
    height: u32,

    // left bearing, px: quad left = pen_x + bearing_x
    bearing_x: i32,

    // top bearing above baseline, px: quad top = baseline_y - bearing_y
    bearing_y: i32,

    // pen advance, px
    advance: i32,

    coverage: []const u8,
};

pub const Rasterizer = struct {
    lib: ft.FT_Library,
    face: ft.FT_Face,

    pub fn init(font_path: [:0]const u8, px_size: u32) Error!Rasterizer {
        var lib: ft.FT_Library = null;

        if (ft.FT_Init_FreeType(&lib) != 0) return error.Init;

        errdefer _ = ft.FT_Done_FreeType(lib);

        var face: ft.FT_Face = null;

        if (ft.FT_New_Face(lib, font_path.ptr, 0, &face) != 0) return error.LoadFace;

        errdefer _ = ft.FT_Done_Face(face);

        if (ft.FT_Set_Pixel_Sizes(face, 0, @intCast(px_size)) != 0) return error.SetSize;

        return .{ .lib = lib, .face = face };
    }

    pub fn deinit(self: *Rasterizer) void {
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.lib);
    }

    /// Rasterize one codepoint into `out` (>= width*height bytes; size it from the
    /// largest atlas cell). FT_LOAD_RENDER loads + renders in one cell,
    /// so face.glyph.bitmap is ready on return
    pub fn rasterize(self: *Rasterizer, codepoint: u21, out: []u8) Error!Glyph {
        if (ft.FT_Load_Char(self.face, @intCast(codepoint), @intCast(ft.FT_LOAD_RENDER)) != 0) return error.LoadGlyph;

        const slot = self.face.*.glyph;
        const bm = slot.*.bitmap;
        const w: u32 = @intCast(bm.width);
        const h: u32 = @intCast(bm.rows);
        const len: usize = @as(usize, w) * @as(usize, h);

        std.debug.assert(len <= out.len);

        // FreeType rows are `pitch` bytes apart (>= width, maybe bottom-up via a
        // negative pitch); repack tight, stride = width, top-down
        if (len != 0) {
            const pitch: usize = @intCast(@abs(bm.pitch));
            const wz: usize = w;
            const hz: usize = h;
            var row: usize = 0;

            while (row < hz) : (row += 1) {
                @memcpy(out[row * wz ..][0..wz], bm.buffer[row * pitch .. row * pitch + wz]);
            }
        }

        return .{
            .width = w,
            .height = h,
            .bearing_x = @intCast(slot.*.bitmap_left),
            .bearing_y = @intCast(slot.*.bitmap_top),
            // 26.6 fixed point -> px
            .advance = @intCast(slot.*.advance.x >> 6),
            .coverage = out[0..len],
        };
    }

    pub fn setPixelSize(self: *Rasterizer, px: u32) Error!void {
        if (ft.FT_Set_Pixel_Sizes(self.face, 0, @intCast(px)) != 0) return error.SetSize;
    }
};
