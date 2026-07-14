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

// arm64 unified memory: render targets can be Shared
const MTLStorageModeShared: u64 = 0;

pub const Error = error{ NoDevice, NoQueue, NoTexture };

pub const Metal = struct {
    device: Id,
    queue: Id,

    pub fn init() Error!Metal {
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoDevice;
        const queue = msg0(device, sel("newCommandQueue")) orelse return error.NoQueue;

        return .{
            .device = device,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Metal) void {
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
