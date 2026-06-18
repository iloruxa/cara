//! Renderer-owned glyph atlas layout
//!
//! It calls `alloc` for each new glyph to get a position in the
//! atlas texture, then streams that glyph's coverage to that position
//! through the staging atlas stream.
//!
//! The host only mirrors the texture - it never packs.
//!
//! Shelf packing: glyphs fill a row left to right; when one will not
//! fit, a new row opens below the tallest glyph of the previous row

const std = @import("std");

/// A placement in the atlas - in texels
/// Maps directly onto staging.AtlasEntry's atlas_x/atlas_y/width/height
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Packer = struct {
    width: u32,
    height: u32,

    // gutter between glyphs,
    // so sampling one never bleeds into its neighbour
    pad: u32 = 1,

    // top of the current row
    shelf_y: u32 = 0,

    // height of the current row (its tallest glyph)
    shelf_h: u32 = 0,

    // next free x on the current row
    x: u32 = 0,

    pub const Full = error{AtlasFull};

    pub fn init(width: u32, height: u32) Packer {
        return .{ .width = width, .height = height };
    }

    /// Reserve a w x h cell, returns its top-left in the atlas
    /// or AtlasFull when the atlas cannot hold it
    pub fn alloc(self: *Packer, w: u32, h: u32) Full!Rect {
        // bigger than the atlas itself
        if (w > self.width or h > self.height) return error.AtlasFull;

        // Open a new row if this glyph would run off the right edge
        if (self.x + w > self.width) {
            self.shelf_y += self.shelf_h + self.pad;
            self.shelf_h = 0;
            self.x = 0;
        }

        // out of rows
        if (self.shelf_y + h > self.height) return error.AtlasFull;

        const rect = Rect{ .x = self.x, .y = self.shelf_y, .w = w, .h = h };

        self.x += w + self.pad;

        if (h > self.shelf_h) self.shelf_h = h;

        return rect;
    }
};

// --- Tests ---
const testing = std.testing;

test "first glyph sits at the origin" {
    var p = Packer.init(256, 256);
    const r = try p.alloc(10, 20);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 10, .h = 20 }, r);
}

test "a row fills left to right with a gutter" {
    var p = Packer.init(256, 256);
    const a = try p.alloc(10, 16);
    const b = try p.alloc(12, 16);
    try testing.expectEqual(@as(u32, 0), a.x);
    try testing.expectEqual(@as(u32, 11), b.x); // 10 + pad(1)
    try testing.expectEqual(@as(u32, 0), b.y);
}

test "wraps to a new row when the current one is full" {
    var p = Packer.init(20, 256);
    _ = try p.alloc(10, 8); // x: 0 -> 11
    const b = try p.alloc(10, 5); // 11 + 10 = 21 > 20 -> new row
    try testing.expectEqual(@as(u32, 0), b.x);
    try testing.expectEqual(@as(u32, 9), b.y); // shelf_h(8) + pad(1)
}

test "row height tracks the tallest glyph on it" {
    var p = Packer.init(64, 256);
    _ = try p.alloc(10, 5); // short
    _ = try p.alloc(10, 30); // tall, same row
    const c = try p.alloc(60, 4); // 22 + 60 > 64 -> new row, below the tall glyph
    try testing.expectEqual(@as(u32, 0), c.x);
    try testing.expectEqual(@as(u32, 31), c.y); // shelf_h(30) + pad(1)
}

test "AtlasFull when the rows run out" {
    var p = Packer.init(10, 18);
    _ = try p.alloc(10, 10); // row 0 at y=0
    try testing.expectError(error.AtlasFull, p.alloc(10, 10)); // new row at y=11; 11+10 > 18
}

test "a glyph larger than the atlas is rejected" {
    var p = Packer.init(64, 64);
    try testing.expectError(error.AtlasFull, p.alloc(65, 10));
    try testing.expectError(error.AtlasFull, p.alloc(10, 65));
}
