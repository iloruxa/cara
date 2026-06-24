//! The renderer's scene graph: a data-oriented ECS.
//! Components live in parallel arrays (SoA) inexed by an entity's slot
//! the tree is first-child/next-sibling links;
//! DirtyFlags gate which entities re-run style/layout/paint
//! Entity is a packed u32 (index + generation) so it fits the R32Uint
//! ID Buffer and the generation makes a recycled slot's old handle
//! detectably stale (hit-test safety); Fixed capacity for now

const std = @import("std");
const style_mod = @import("style.zig");
pub const Style = style_mod.Style;

pub const max_entities = 4096;
const none_index: u24 = std.math.maxInt(u24);

/// A generational handle
/// `index` selects the SoA slota, `generation` is bumped when the slot
/// is freed, so a handle to recycled slot fails `isValid`
pub const Entity = packed struct {
    index: u24,
    generation: u8,

    pub const none = Entity{ .index = none_index, .generation = 0 };

    pub fn isNone(e: Entity) bool {
        return e.index == none_index;
    }
};

pub const NodeKind = enum(u8) {
    root,
    box,
    text,
    button,
    image,
    component,
    span,
    _,
};

/// Which passes an entity still needs
/// Start dirty; passes clear their bit
pub const DirtyFlags = packed struct {
    style: bool = true,
    layout: bool = true,
    paint: bool = true,
    _pad: u5 = 0,
};

/// Markdown modifiers for a styled text span
/// A register-resident u32 bitmask: opening a token sets a bit
/// closing clears it, emiting a span copies the mask
/// No nesting stack by desing
pub const Mask = packed struct {
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    code: bool = false,
    link: bool = false,
    _pad: u27 = 0,
};

/// A styled text span
/// A slice of content + its mask (+url when it is a link)
/// Slices point into the source (zero-copy);
/// the parse keeps the source alive
pub const SpanData = struct { text: []const u8 = "", url: []const u8 = "", mask: Mask = .{} };

/// An entity's laid-out box: absolute origin + size in framebuffer pixels,
/// written by the layout pass, read by paint
pub const Box = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Entity) == 4);
    std.debug.assert(@sizeOf(DirtyFlags) == 1);
}

/// Heap-allocate one of these (it is ~90 KiB), then call `init`
pub const Scene = struct {
    // SoA: parallel arrays, one row per slot
    // `generation` persists across recycle (only `destroy bumps it`)
    // the rest are (re)set by `create`
    generation: [max_entities]u8,
    kind: [max_entities]NodeKind,
    parent: [max_entities]Entity,
    first_child: [max_entities]Entity,
    last_child: [max_entities]Entity,
    next_sibling: [max_entities]Entity,
    dirty: [max_entities]DirtyFlags,
    style: [max_entities]Style,
    span: [max_entities]SpanData,
    box: [max_entities]Box,

    // Luau handler name from onClick=$name. "" = none
    on_click: [max_entities][]const u8,

    // slots ever handed out
    high_water: u24,

    // recycled slot indices
    free: [max_entities]u24,

    // signal name a node's content binds to ($name); "" = none
    bind: [max_entities][]const u8,

    // scratch for a bound node's formatted value
    num_buf: [max_entities][24]u8,

    free_len: u24,

    pub const Error = error{SceneFull};

    pub fn init(self: *Scene) void {
        self.high_water = 0;
        self.free_len = 0;
        @memset(self.generation[0..], 0);
    }

    pub fn create(self: *Scene, kind: NodeKind) Error!Entity {
        var idx: u24 = undefined;

        if (self.free_len > 0) {
            self.free_len -= 1;
            idx = self.free[self.free_len];
        } else {
            if (self.high_water >= max_entities) return error.SceneFull;
            idx = self.high_water;
            self.high_water += 1;
        }

        self.kind[idx] = kind;
        self.parent[idx] = Entity.none;
        self.first_child[idx] = Entity.none;
        self.last_child[idx] = Entity.none;
        self.next_sibling[idx] = Entity.none;
        self.dirty[idx] = .{};
        self.style[idx] = .{};
        self.span[idx] = .{};
        self.box[idx] = .{};
        self.on_click[idx] = "";
        self.bind[idx] = "";

        return .{ .index = idx, .generation = self.generation[idx] };
    }

    /// Reclaim a slot
    /// Bumps its generation so every existing handle to it dies
    /// Does not detach from the tree (the scene is rebuilt per document for now)
    pub fn destroy(self: *Scene, e: Entity) void {
        self.generation[e.index] +%= 1;
        self.free[self.free_len] = e.index;
        self.free_len += 1;
    }

    pub fn isValid(self: *const Scene, e: Entity) bool {
        return e.index < self.high_water and self.generation[e.index] == e.generation;
    }

    /// Append `child` as the last child of `parent` (O(1) via last_child)
    pub fn appendChild(self: *Scene, parent: Entity, child: Entity) void {
        self.parent[child.index] = parent;
        self.next_sibling[child.index] = Entity.none;

        if (self.first_child[parent.index].isNone()) {
            self.first_child[parent.index] = child;
        } else {
            self.next_sibling[self.last_child[parent.index].index] = child;
        }

        self.last_child[parent.index] = child;
    }

    pub const ChildIterator = struct {
        scene: *const Scene,
        cur: Entity,

        pub fn next(it: *ChildIterator) ?Entity {
            if (it.cur.isNone()) return null;

            const e = it.cur;

            it.cur = it.scene.next_sibling[e.index];

            return e;
        }
    };

    pub fn children(self: *const Scene, parent: Entity) ChildIterator {
        return .{
            .scene = self,
            .cur = self.first_child[parent.index],
        };
    }

    pub fn markDirty(self: *Scene, e: Entity, flags: DirtyFlags) void {
        const d = &self.dirty[e.index];

        if (flags.style) d.style = true;

        if (flags.layout) d.layout = true;

        if (flags.paint) d.paint = true;
    }
};

// --- Tests ---
const testing = std.testing;

fn freshScene() !*Scene {
    const s = try testing.allocator.create(Scene);
    s.init();
    return s;
}

test "create yields valid, distinct handles" {
    const s = try freshScene();
    defer testing.allocator.destroy(s);
    const a = try s.create(.box);
    const b = try s.create(.text);
    try testing.expect(s.isValid(a));
    try testing.expect(s.isValid(b));
    try testing.expect(a.index != b.index);
    try testing.expectEqual(NodeKind.box, s.kind[a.index]);
}

test "appendChild builds an ordered child list" {
    const s = try freshScene();
    defer testing.allocator.destroy(s);
    const root = try s.create(.root);
    const a = try s.create(.box);
    const b = try s.create(.box);
    const c = try s.create(.text);
    s.appendChild(root, a);
    s.appendChild(root, b);
    s.appendChild(root, c);

    var it = s.children(root);
    try testing.expectEqual(a.index, (it.next().?).index);
    try testing.expectEqual(b.index, (it.next().?).index);
    try testing.expectEqual(c.index, (it.next().?).index);
    try testing.expect(it.next() == null);
}

test "destroy invalidates old handles and recycles the slot" {
    const s = try freshScene();
    defer testing.allocator.destroy(s);
    const a = try s.create(.box);
    s.destroy(a);
    try testing.expect(!s.isValid(a)); // old handle dead

    const b = try s.create(.text); // reuses the freed slot
    try testing.expectEqual(a.index, b.index); // same index
    try testing.expect(b.generation != a.generation); // new generation
    try testing.expect(s.isValid(b));
    try testing.expect(!s.isValid(a)); // a stays dead
}
