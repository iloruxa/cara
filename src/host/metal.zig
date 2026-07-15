//! Metal backend, interacting via objc runtime

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!builtin.os.tag.isDarwin()) @compileError("metal.zig is darwin-only. Linux uses Vulkan");
}

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

extern fn objc_msgSend() void;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern fn MTLCreateSystemDefaultDevice() Id;

fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

// objc_msgSend cast to each concrete signature we call
// arm64: one entry point for all, the compiler places args per the C ABI which
// is why the struct-by-value calls below must match Apple's layout exactly
fn msg0(self: Id, s: Sel) Id {
    return @as(*const fn (Id, Sel) callconv(.c) Id, @ptrCast(&objc_msgSend))(self, s);
}

fn msg0v(self: Id, s: Sel) void {
    @as(*const fn (Id, Sel) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s);
}

fn msgId(self: Id, s: Sel, a: Id) Id {
    return @as(*const fn (Id, Sel, Id) callconv(.c) Id, @ptrCast(&objc_msgSend))(self, s, a);
}

fn msgSetId(self: Id, s: Sel, a: Id) void {
    @as(*const fn (Id, Sel, Id) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, a);
}

fn msgSetU(self: Id, s: Sel, a: u64) void {
    @as(*const fn (Id, Sel, u64) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, a);
}

fn msgIdxId(self: Id, s: Sel, i: u64) Id {
    return @as(*const fn (Id, Sel, u64) callconv(.c) Id, @ptrCast(&objc_msgSend))(self, s, i);
}

fn msgSetClearColor(self: Id, s: Sel, cc: MTLClearColor) void {
    @as(*const fn (Id, Sel, MTLClearColor) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, cc);
}

fn msgTexDesc(cls: Id, s: Sel, fmt: u64, w: u64, h: u64, mip: bool) Id {
    return @as(*const fn (Id, Sel, u64, u64, u64, bool) callconv(.c) Id, @ptrCast(&objc_msgSend))(cls, s, fmt, w, h, mip);
}

fn msgGetBytes(self: Id, s: Sel, bytes: [*]u8, bpr: u64, region: MTLRegion, level: u64) void {
    @as(*const fn (Id, Sel, [*]u8, u64, MTLRegion, u64) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, bytes, bpr, region, level);
}

fn msgStr(cls: Id, s: Sel, str: [*:0]const u8) Id {
    return @as(*const fn (Id, Sel, [*:0]const u8) callconv(.c) Id, @ptrCast(&objc_msgSend))(cls, s, str);
}

fn msgCStr(self: Id, s: Sel) ?[*:0]const u8 {
    return @as(*const fn (Id, Sel) callconv(.c) [*:0]const u8, @ptrCast(&objc_msgSend))(self, s);
}

fn msgNewLib(self: Id, s: Sel, src: Id, opts: Id, err: *Id) Id {
    return @as(*const fn (Id, Sel, Id, Id, *Id) callconv(.c) Id, @ptrCast(&objc_msgSend))(self, s, src, opts, err);
}

fn msgNewPso(self: Id, s: Sel, desc: Id, err: *Id) Id {
    return @as(*const fn (Id, Sel, Id, *Id) callconv(.c) Id, @ptrCast(&objc_msgSend))(self, s, desc, err);
}

fn msgNewBuf(self: Id, s: Sel, bytes: *const anyopaque, len: u64, opts: u64) Id {
    return @as(*const fn (Id, Sel, *const anyopaque, u64, u64) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, bytes, len, opts);
}

fn msgSetBuf(self: Id, s: Sel, buf: Id, offset: u64, index: u64) void {
    @as(*const fn (Id, Sel, Id, u64, u64) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, bytes, offset, index);
}

fn msgSetBytes(self: Id, s: Sel, bytes: *const anyopaque, len: u64, index: u64) void {
    @as(*const fn (Id, Sel, *const anyopaque, u64, u64) callconv(.c), @ptrCast(&objc_msgSend))(self, s, bytes, len, index);
}

fn msgDraw(self: Id, s: Sel, prim: u64, start: u64, count: u64, instances: u64) void {
    @as(*const fn (Id, Sel, u64, u64, u64, u64) callconv(.c) void, @ptrCast(&objc_msgSend))(self, s, prim, start, count, instances);
}

// --- Metal ABI structs ---
const MTLClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
const MTLOrigin = extern struct { x: usize, y: usize, z: usize };
const MTLSize = extern struct { width: usize, height: usize, depth: usize };
const MTLRegion = extern struct { origin: MTLOrigin, size: MTLSize };

// Enum values from <Metal/*.h>
const MTLPixelFormatBGRA8Unorm: u64 = 80;
const MTLLoadActionClear: u64 = 2;
const MTLStoreActionStore: u64 = 1;
const MTLTextureUsageRenderTarget: u64 = 4;
const MTLPrimitiveTypeTriangle: u64 = 3;

// MTLResourceOptions: storage mode in bits 4-7, Shared = 0
const MTLResourceStorageModeShared: u64 = 0;

// arm64 unified memory: render targets can be Shared
const MTLStorageModeShared: u64 = 0;

/// Mirrors gpu.zig's RectInstance - Becomes the seam type after this is done
pub const RectInstance = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    rgba: u32,
    entity: u32,
};

comptime {
    // The MSL RectInstance mirror below assumes this exact 24-byte layout
    std.debug.assert(@sizeOf(RectInstance) == 24);
}

// Instanced rect: 6 vertices per instance, corner from vertex_id,
// instance data fetched by instance_id (no vertex descriptor needed)
// entity is carried for the ID attachment (next step); unused here
const rect_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct RectInstance { float2 pos; float2 size; uint rgba; uint entity; };
    \\struct VsOut { float4 pos [[position]]; float4 color; };
    \\vertex VsOut rect_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\                     const device RectInstance* rects [[buffer(0)]],
    \\                     constant float2& viewport [[buffer(1)]]) {
    \\    float2 corner[6] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    \\                         float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0) };
    \\    RectInstance r = rects[iid];
    \\    float2 pixel = r.pos + corner[vid] * r.size;
    \\    float2 clip = float2(pixel.x / viewport.x * 2.0 - 1.0,
    \\                         1.0 - pixel.y / viewport.y * 2.0);
    \\    VsOut out;
    \\    out.pos = float4(clip, 0.0, 1.0);
    \\    out.color = float4(float((r.rgba >> 24) & 255u) / 255.0,
    \\                       float((r.rgba >> 16) & 255u) / 255.0,
    \\                       float((r.rgba >> 8) & 255u) / 255.0,
    \\                       float(r.rgba & 255u) / 255.0);
    \\    return out;
    \\}
    \\fragment float4 rect_fs(VsOut in [[stage_in]]) { return in.color; }
;

fn logNsError(what: []const u8, err: Id) void {
    const desc = msg0(err, sel("localizedDescription")) orelse {
        std.debug.print("HOST: metal {s} failed (no NSError)\n", .{what});
        return;
    };

    const cstr = msgCStr(desc, sel("UTF8String")) orelse return;

    std.debug.print("HOST: metal {s} failed: {s}\n", .{what, cstr});
}

pub const Error = error{ NoDevice, NoQueue, NoTexture, NoLibrary, NoFunction, NoPipeline, NoBuffer };

pub const Metal = struct {
    device: Id,
    queue: Id,
    rect_pso: Id,

    pub fn init() Error!Metal {
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoDevice;
        const queue = msg0(device, sel("newCommandQueue")) orelse return error.NoQueue;

        // Shader compile spawns autorelease objects - (NSString, NSError)
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const ns_string = objc_getClass("NSString");
        const src = msgStr(ns_string, sel("stringWithUTF8String:"), rect_msl);

        var err: Id = null;
        const lib = msgNewLib(device, sel("newLibraryWithSource:options:error:"), src, null, &err) orelse {
            logNsError("shader compile", err);
            return error.NoLibrary;
        };
        defer msg0v(lib, sel("release"));

        const vs = msgId(lib, sel("newFunctionWithName:"), msgStr(ns_string, sel("stringWithUTF8String:"), "rect_vs")) orelse return error.NoFunction;
        defer msg0v(vs, sel("release"));

        const fs = msgId(lib, sel("newFunctionWithName:"), msgStr(ns_string, sel("stringWithUTF8String:"), "rect_fs")) orelse return error.NoFunction;
        defer msg0v(fs, sel("release"));

        const desc = msg0(objc_getClass("MTLRenderPipelineDescriptor"), sel("new"));
        defer msg0v(desc, sel("release"));

        msgSetId(desc, sel("setVertexFunction:"), vs);
        msgSetId(desc, sel("setFragmentFunction:"), fs);

        const att0 = msgIdxId(msg0(desc, sel("colorAttachments")), sel("objectAtIndexedSubscript:"), 0);
        msgSetU(att0, sel("setPixelFormat:"), MTLPixelFormatBGRA8Unorm);

        err = null;
        const rect_pso = msgNewPso(device, sel("newRenderPipelineStateWithDescriptor:error:"), desc, &err) orelse {
            logNsError("rect pipeline", err);
            return error.NoPipeline;
        };

        return .{
            .device = device,
            .queue = queue,
            .rect_pso = rect_pso,
        };
    }

    pub fn deinit(self: *Metal) void {
        msg0v(self.rect_pso, sel("release"));
        msg0v(self.queue, sel("release"));
        msg0v(self.device, sel("release"));
    }

    // Clear a 1x1 offscreen BGRA texture to `color`, commit, and read the texel
    // back
    // * Returns bytes in memory order: B, G, R, A
    pub fn clearReadBack(self: Metal, red: f64, green: f64, blue: f64, alpha: f64) Error![4]u8 {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        const desc = msgTexDesc(objc_getClass("MTLTextureDescriptor"), sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), MTLPixelFormatBGRA8Unorm, 1, 1, false);
        msgSetU(desc, sel("setUsage:"), MTLTextureUsageRenderTarget);
        msgSetU(desc, sel("setStorageMode:"), MTLStorageModeShared);

        const tex = msgId(self.device, sel("newTextureWithDescriptor:"), desc) orelse return error.NoTexture;
        defer msg0v(tex, sel("release"));

        const rpd = msg0(objc_getClass("MTLRenderPassDescriptor"), sel("renderPassDescriptor"));
        const att0 = msgIdxId(msg0(rpd, sel("colorAttachments")), sel("objectAtIndexedSubscript:"), 0);

        msgSetId(att0, sel("setTexture:"), tex);
        msgSetU(att0, sel("setLoadAction:"), MTLLoadActionClear);
        msgSetU(att0, sel("setStoreAction:"), MTLStoreActionStore);
        msgSetClearColor(att0, sel("setClearColor:"), .{ .red = red, .green = green, .blue = blue, .alpha = alpha });

        const cb = msg0(self.queue, sel("commandBuffer"));
        const enc = msgId(cb, sel("renderCommandEncoderWithDescriptor:"), rpd);
        msg0v(enc, sel("endEncoding"));
        msg0v(cb, sel("commit"));
        msg0v(cb, sel("waitUntilCompleted"));

        var px: [4]u8 = undefined;
        const region = MTLRegion{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 1, .height = 1, .depth = 1 } };

        msgGetBytes(tex, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), &px, 4, region, 0);

        return px;
    }
};

// Draw instanced rects into a w x h offscreen BGRA target and read the whole
// target back into `out`
// Proof path: on-screen step swaps the offscreen texture for a CAMetalLayer
// drawable, everything else stays
pub fn drawRectsReadBack(self: Metal, w: usize, h: usize, rects: []const RectInstance, out: []u8) Error!void {
    std.debug.assert(out.len >= w * h * 4);
}

// --- Testing ---
const testing = std.testing;

test "metal clears an offscreen texture to a known color and reads it back" {
    // headless / no GPU: skip
    var m = Metal.init() catch return error.SkipZigTest;
    defer m.deinit();

    // Opaque blue in, BGRA out: B=255, G=0, R=0, A=255
    const px = try m.clearReadBack(0.0, 0.0, 1.0, 1.0);

    // B
    try testing.expectEqual(@as(u8, 255), px[0]);

    // G
    try testing.expectEqual(@as(u8, 0), px[1]);

    // R
    try testing.expectEqual(@as(u8, 0), px[2]);

    // A
    try testing.expectEqual(@as(u8, 255), px[3]);
}
