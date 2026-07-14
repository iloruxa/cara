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
};
