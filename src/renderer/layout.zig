//! Strict-Box Layout: constraints down, sizes up
//!
//! A parent hands each child a Constraint and
//! gets back one Size then positions it
//!
//! No solver, no iteration: measure() runs once per node
//!
//! Two passes total. Flow mode only for now (.flow-col/.flow-row,
//! sequential stacking). Text measurement is injected -
//! a native Trinity call in the renderer, a stub in tests
//! so layout stays testable with no font on disk

const std = @import("std");
const scene_mod = @import("scene.zig");
const style = @import("style.zig");

const Scene = scene_mod.Scene;
const Entity = scene_mod.Entity;

pub const Size = struct {
    w: f32,
    h: f32,
};

pub const Constraint = struct {
    min_w: f32 = 0,
    max_w: f32,
    min_h: f32 = 0,
    max_h: f32,
};

/// Injected text measurement: the renderer backs this with the rasterizer
/// tests pass a deterministic stub, ctx is the backing object,
/// cast inside measureFn
pub const TextMeasurer = struct {
    ctx: *anyopaque,
    measureFn: *const fn (ctx: *anyopaque, text: []const u8, font_px: u32) Size,

    pub fn measure(self: TextMeasurer, text: []const u8, font_px: u32) Size {
        return self.measureFn(self.ctx, text, font_px);
    }
};

fn resolveSize(mode: style.SizeMode, explicit: f32, content: f32, avail: f32) f32 {
    return switch (mode) {
        .explicit => explicit,
        .fill => avail,
        .fit, .auto => content,
    };
}

pub const Layout = struct {
    scene: *Scene,
    measurer: TextMeasurer,

    pub fn run(self: *Layout, root: Entity, viewport_w: f32, viewport_h: f32) void {
        _ = self.measure(root, .{ .max_w = viewport_w, .max_h = viewport_h });
        self.place(root, 0, 0);
    }

    fn measure(self: *Layout, e: Entity, c: Constraint) Size {
        return switch (self.scene.kind[e.index]) {
            .text => self.measureText(e, c),
            // spans are measured by their parent text node
            .span => .{ .w = 0, .h = 0 },
            else => self.measureBox(e, c),
        };
    }

    fn measureBox(self: *Layout, e: Entity, c: Constraint) Size {
        const st = self.scene.style[e.index];
        const pad = st.padding;
        const inner = Constraint{
            .max_w = @max(0.0, c.max_w - 2 * pad),
            .max_h = @max(0.0, c.max_h - 2 * pad),
        };

        var content_w: f32 = 0;
        var content_h: f32 = 0;
        var n: u32 = 0;
        var it = self.scene.children(e);

        while (it.next()) |child| {
            const cs = self.measure(child, inner);

            if (st.flow == .row) {
                content_w += cs.w;
                content_h = @max(content_h, cs.h);
            } else {
                content_h += cs.h;
                content_w = @max(content_w, cs.w);
            }

            n += 1;
        }

        if (n > 1) {
            const gap_total = st.gap * @as(f32, @floatFromInt(n - 1));

            if (st.flow == .row) {
                content_w += gap_total;
            } else {
                content_h += gap_total;
            }
        }

        const w = resolveSize(st.width_mode, st.width, content_w + 2 * pad, c.max_w);
        const h = resolveSize(st.height_mode, st.height, content_h + 2 * pad, c.max_h);

        self.scene.box[e.index] = .{ .w = w, .h = h };

        return .{ .w = w, .h = h };
    }

    fn measureText(self: *Layout, e: Entity, c: Constraint) Size {
        const st = self.scene.style[e.index];
        const pad = st.padding;
        var w_sum: f32 = 0;
        var h_max: f32 = 0;

        // spans
        var it = self.scene.children(e);

        while (it.next()) |span| {
            const sz = self.measurer.measure(self.scene.span[span.index].text, st.font_px);
            self.scene.box[span.index] = .{ .w = sz.w, .h = sz.h };
            w_sum += sz.w;
            h_max = @max(h_max, sz.h);
        }

        const w = resolveSize(st.width_mode, st.width, w_sum + 2 * pad, c.max_w);
        const h = resolveSize(st.height_mode, st.height, h_max + 2 * pad, c.max_h);

        self.scene.box[e.index] = .{
            .w = w,
            .h = h,
        };

        return .{ .w = w, .h = h };
    }

    fn place(self: *Layout, e: Entity, x: f32, y: f32) void {
        self.scene.box[e.index].x = x;
        self.scene.box[e.index].y = y;

        const st = self.scene.style[e.index];
        const pad = st.padding;

        if (self.scene.kind[e.index] == .text) {
            // spans flow left to right on one line (wrapping is later)
            var cursor_x = x + pad;
            var it = self.scene.children(e);

            while (it.next()) |span| {
                self.scene.box[span.index].x = cursor_x;
                self.scene.box[span.index].y = y + pad;
                cursor_x += self.scene.box[span.index].w;
            }

            return;
        }

        var cursor_x = x + pad;
        var cursor_y = y + pad;
        var it = self.scene.children(e);

        while (it.next()) |child| {
            self.place(child, cursor_x, cursor_y);

            if (st.flow == .row) {
                cursor_x += self.scene.box[child.index].w + st.gap;
            } else {
                cursor_y += self.scene.box[child.index].h + st.gap;
            }
        }
    }
};

// --- Tests ---
const testing = std.testing;

fn stubMeasure(ctx: *anyopaque, text: []const u8, font_px: u32) Size {
    _ = ctx;
    // deterministic: each char is half the font size wide; line height = font size
    return .{
        .w = @as(f32, @floatFromInt(text.len)) * @as(f32, @floatFromInt(font_px)) * 0.5,
        .h = @floatFromInt(font_px),
    };
}

fn stubLayout(s: *Scene) Layout {
    const dummy = struct {
        var b: u8 = 0;
    };
    return .{ .scene = s, .measurer = .{ .ctx = &dummy.b, .measureFn = stubMeasure } };
}

test "flow-col stacks children with gap and padding; fit sizes to content" {
    const s = try testing.allocator.create(Scene);
    defer testing.allocator.destroy(s);
    s.init();

    const root = try s.create(.box);
    s.style[root.index] = .{ .flow = .col, .padding = 4, .gap = 2, .width_mode = .fit, .height_mode = .fit };
    const a = try s.create(.box);
    s.style[a.index] = .{ .width = 20, .width_mode = .explicit, .height = 10, .height_mode = .explicit };
    const b = try s.create(.box);
    s.style[b.index] = .{ .width = 40, .width_mode = .explicit, .height = 10, .height_mode = .explicit };
    s.appendChild(root, a);
    s.appendChild(root, b);

    var lay = stubLayout(s);
    lay.run(root, 1000, 1000);

    try testing.expectEqual(@as(f32, 4), s.box[a.index].x);
    try testing.expectEqual(@as(f32, 4), s.box[a.index].y);
    try testing.expectEqual(@as(f32, 4), s.box[b.index].x);
    try testing.expectEqual(@as(f32, 16), s.box[b.index].y); // 4 + a.h(10) + gap(2)
    try testing.expectEqual(@as(f32, 48), s.box[root.index].w); // max(20,40) + 2*4
    try testing.expectEqual(@as(f32, 30), s.box[root.index].h); // 10+2+10 + 2*4
}

test "fill width consumes the parent's available width" {
    const s = try testing.allocator.create(Scene);
    defer testing.allocator.destroy(s);
    s.init();

    const root = try s.create(.box);
    s.style[root.index] = .{ .flow = .col, .width_mode = .fill, .height_mode = .fit };
    const a = try s.create(.box);
    s.style[a.index] = .{ .width_mode = .fill, .height = 10, .height_mode = .explicit };
    s.appendChild(root, a);

    var lay = stubLayout(s);
    lay.run(root, 800, 600);

    try testing.expectEqual(@as(f32, 800), s.box[root.index].w);
    try testing.expectEqual(@as(f32, 800), s.box[a.index].w);
}

test "text node sizes to its spans via the injected measurer" {
    const s = try testing.allocator.create(Scene);
    defer testing.allocator.destroy(s);
    s.init();

    const t = try s.create(.text);
    s.style[t.index] = .{ .font_px = 32, .width_mode = .fit, .height_mode = .fit };
    const sp1 = try s.create(.span);
    s.span[sp1.index] = .{ .text = "ab" }; // len 2
    const sp2 = try s.create(.span);
    s.span[sp2.index] = .{ .text = "cde" }; // len 3
    s.appendChild(t, sp1);
    s.appendChild(t, sp2);

    var lay = stubLayout(s);
    lay.run(t, 1000, 1000);

    try testing.expectEqual(@as(f32, 32), s.box[sp1.index].w); // 2 * 32 * 0.5
    try testing.expectEqual(@as(f32, 48), s.box[sp2.index].w); // 3 * 32 * 0.5
    try testing.expectEqual(@as(f32, 80), s.box[t.index].w); // 32 + 48
    try testing.expectEqual(@as(f32, 32), s.box[t.index].h);
    try testing.expectEqual(@as(f32, 0), s.box[sp1.index].x);
    try testing.expectEqual(@as(f32, 32), s.box[sp2.index].x); // after sp1
}
