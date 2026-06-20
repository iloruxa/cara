//! Style resolver
//! maps .utility tokens onto a per-entity Style component
//! Fixed keywords match directly; parametric families (p-N, p-N, bg-COLOR,
//! text-SIZE/COLOR) are split with cutScalar and parsed, so the table stays
//! small and p-1..p-96 need not be enumerated
//!
//! A compile-time perfect hash over the fixed keywords is a later optimization
//! This is a representative subset of the ~220-utility vocabulary, structured
//! so more is mechanical

const std = @import("std");

pub const Flow = enum(u8) { col, row };
pub const SizeMode = enum(u8) { auto, explicit, fill, fit };

pub const Style = struct {
    flow: Flow = .col,

    // 0xRRGGBBAA; a = 0 means "no background" (paint emits no rect)
    bg: u32 = 0x000000,

    // text color: white
    fg: u32 = 0xFFFFFFFF,

    padding: f32 = 0.0,
    gap: f32 = 0.0,
    width: f32 = 0.0,
    width_mode: SizeMode = .auto,
    height: f32 = 0.0,
    height_mode: SizeMode = .auto,
    font_px: u32 = 32,

    // stored; not yet rendered
    bold: bool = false,
};

// px per spacing step (Tailwind-like 0.25rem)
const space_unit: f32 = 4;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn number(s: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, s) catch null;
}

fn color(name: []const u8) ?u32 {
    if (eq(name, "white")) return 0xFFFFFFFF;
    if (eq(name, "black")) return 0x000000FF;
    if (eq(name, "transparent")) return 0x00000000;
    if (eq(name, "blue-500")) return 0x3B82F6FF;
    if (eq(name, "gray-100")) return 0xF3F4F6FF;
    if (eq(name, "gray-800")) return 0x1F2937FF;
    if (eq(name, "gray-900")) return 0x111827FF;
    if (eq(name, "red-500")) return 0xEF4444FF;
    if (eq(name, "green-500")) return 0x22C55EFF;

    return null;
}

fn fontSize(name: []const u8) ?u32 {
    if (eq(name, "sm")) return 24;
    if (eq(name, "base")) return 32;
    if (eq(name, "lg")) return 40;
    if (eq(name, "xl")) return 48;
    if (eq(name, "2xl")) return 64;
    if (eq(name, "3xl")) return 80;

    return null;
}

/// Resolve one .utility token onto `style`
/// * Returns false for an unrecognized token (silently ignored for now;
/// styles.glyph and strict diagnostics later)
pub fn resolve(style: *Style, util: []const u8) bool {
    // exact-match keywords
    if (eq(util, "flow-col")) {
        style.flow = .col;
        return true;
    }

    if (eq(util, "flow-row")) {
        style.flow = .row;
        return true;
    }

    if (eq(util, "bold")) {
        style.bold = true;
        return true;
    }

    if (eq(util, "fill-w")) {
        style.width_mode = .fill;
        return true;
    }

    if (eq(util, "fill-h")) {
        style.height_mode = .fill;
        return true;
    }

    if (eq(util, "fit-w")) {
        style.width_mode = .fit;
        return true;
    }

    if (eq(util, "fit-h")) {
        style.height_mode = .fit;
        return true;
    }

    // prefix-value families: split on the first '-'
    const before, const after = std.mem.cutScalar(u8, util, '-') orelse return false;

    if (eq(before, "p")) {
        if (number(after)) |n| {
            style.padding = n * space_unit;
            return true;
        }
    } else if (eq(before, "gap")) {
        if (number(after)) |n| {
            style.gap = n * space_unit;
            return true;
        }
    } else if (eq(before, "w")) {
        if (eq(after, "full")) {
            style.width_mode = .fill;
            return true;
        }

        if (number(after)) |n| {
            style.width = n * space_unit;
            style.width_mode = .explicit;
            return true;
        }
    } else if (eq(before, "h")) {
        if (eq(after, "full")) {
            style.height_mode = .fill;
            return true;
        }

        if (number(after)) |n| {
            style.height = n * space_unit;
            style.height_mode = .explicit;
            return true;
        }
    } else if (eq(before, "bg")) {
        if (color(after)) |c| {
            style.bg = c;
            return true;
        }
    } else if (eq(before, "text")) {
        if (fontSize(after)) |px| {
            style.font_px = px;
            return true;
        }

        if (color(after)) |c| {
            style.fg = c;
            return true;
        }
    }

    return false;
}

// --- Tests ---
const testing = std.testing;

test "resolver maps representative utilities, ignores unknowns" {
    var st = Style{};
    try testing.expect(resolve(&st, "flow-row"));
    try testing.expectEqual(Flow.row, st.flow);

    try testing.expect(resolve(&st, "p-8"));
    try testing.expectEqual(@as(f32, 32), st.padding);

    try testing.expect(resolve(&st, "bg-blue-500"));
    try testing.expectEqual(@as(u32, 0x3B82F6FF), st.bg);

    try testing.expect(resolve(&st, "text-2xl"));
    try testing.expectEqual(@as(u32, 64), st.font_px);

    try testing.expect(resolve(&st, "text-white"));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), st.fg);

    try testing.expect(resolve(&st, "w-full"));
    try testing.expectEqual(SizeMode.fill, st.width_mode);

    try testing.expect(!resolve(&st, "made-up-token"));
    try testing.expect(!resolve(&st, "rounded")); // not in the subset yet, ignored
}
