const draw = @import("draw");
const glfw = @import("glfw");
const protocol = @import("protocol");
const ring = @import("ring");
const std = @import("std");
const wgpu = @import("wgpu");
const net = std.Io.net;

// --- Cocoa = Ojb-C glue : No zig-native path for creating CAMetalLayer ---
extern fn glfwGetCocoaWindow(window: ?*anyopaque) ?*anyopaque;
extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void;

fn metalLayerForWindow(ns_window: ?*anyopaque) ?*anyopaque {
    const msg_id = @as(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque, @ptrCast(&objc_msgSend));
    const msg_set_id = @as(*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void, @ptrCast(&objc_msgSend));
    const msg_set_bool = @as(*const fn (?*anyopaque, ?*anyopaque, bool) callconv(.c) void, @ptrCast(&objc_msgSend));

    const view = msg_id(ns_window, sel_registerName("contentView")) orelse
        return null;
    const layer = msg_id(objc_getClass("CAMetalLayer"), sel_registerName("layer")) orelse return null;

    msg_set_bool(view, sel_registerName("setWantsLayer:"), true);
    msg_set_id(view, sel_registerName("setLayer:"), layer);

    return layer;
}

// --- GPU: adapter/device async requests ---
const AdapterReq = struct { adapter: wgpu.WGPUAdapter = null, done: bool = false };

fn onAdapter(status: wgpu.WGPURequestAdapterStatus, adapter: wgpu.WGPUAdapter, message: wgpu.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = status;
    _ = message;
    _ = ud2;

    const req: *AdapterReq = @ptrCast(@alignCast(ud1));
    req.adapter = adapter;
    req.done = true;
}

const DeviceReq = struct { device: wgpu.WGPUDevice = null, done: bool = false };

fn onDevice(status: wgpu.WGPURequestDeviceStatus, device: wgpu.WGPUDevice, message: wgpu.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = status;
    _ = message;
    _ = ud2;

    const req: *DeviceReq = @ptrCast(@alignCast(ud1));
    req.device = device;
    req.done = true;
}

// --- GPU: rectangle pipeline ---
// Multi-line string
const rect_wgsl =
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    \\    var p = array<vec2<f32>, 3>(
    \\        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0)
    \\    );
    \\    return vec4<f32>(p[i], 0.0, 1.0);
    \\}
    \\@fragment fn fs() -> @location(0) vec4<f32> {
    \\    return vec4<f32>(0.231, 0.510, 0.965, 1.0); // 0x3B82F6 — hardcoded; P3-2b: from rgba
    \\}
;

fn sv(s: []const u8) wgpu.WGPUStringView {
    return .{
        .data = s.ptr,
        .length = s.len,
    };
}

fn createRectPipeline(device: wgpu.WGPUDevice) ?wgpu.WGPURenderPipeline {
    var wgsl = wgpu.WGPUShaderSourceWGSL{
        .chain = .{ .sType = @intCast(wgpu.WGPUSType_ShaderSourceWGSL) },
        .code = sv(rect_wgsl),
    };
    const sm_desc = wgpu.WGPUShaderModuleDescriptor{ .nextInChain = &wgsl.chain };
    const module = wgpu.wgpuDeviceCreateShaderModule(device, &sm_desc) orelse return null;
    defer wgpu.wgpuShaderModuleRelease(module);

    const color_target = wgpu.WGPUColorTargetState{
        .format = @intCast(wgpu.WGPUTextureFormat_BGRA8Unorm),
        .writeMask = wgpu.WGPUColorWriteMask_All,
    };

    const fragment = wgpu.WGPUFragmentState{
        .module = module,
        .entryPoint = sv("fs"),
        .targetCount = 1,
        .targets = &color_target,
    };
    const desc = wgpu.WGPURenderPipelineDescriptor{
        .vertex = .{ .module = module, .entryPoint = sv("vs") },
        .primitive = .{
            .topology = @intCast(wgpu.WGPUPrimitiveTopology_TriangleList),
            .frontFace = @intCast(wgpu.WGPUFrontFace_CCW),
            .cullMode = @intCast(wgpu.WGPUCullMode_None),
        },
        .multisample = .{ .count = 1, .mask = 0xFFFF_FFFF },
        .fragment = &fragment,
    };

    return wgpu.wgpuDeviceCreateRenderPipeline(device, &desc);
}

// --- per-frame paint: clear, then the rect (scissor-clipped) ---
fn paint(surface: wgpu.WGPUSurface, device: wgpu.WGPUDevice, queue: wgpu.WGPUQueue, pipeline: wgpu.WGPURenderPipeline, rect: ?draw.DrawRect) void {
    var st: wgpu.WGPUSurfaceTexture = undefined;
    wgpu.wgpuSurfaceGetCurrentTexture(surface, &st);

    const texture = st.texture orelse return;
    defer wgpu.wgpuTextureRelease(texture);

    const view = wgpu.wgpuTextureCreateView(texture, null) orelse return;
    defer wgpu.wgpuTextureViewRelease(view);

    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(device, null) orelse return;
    defer wgpu.wgpuCommandEncoderRelease(encoder);

    const color = wgpu.WGPURenderPassColorAttachment{
        .view = view,
        .depthSlice = @intCast(wgpu.WGPU_DEPTH_SLICE_UNDEFINED),
        .loadOp = @intCast(wgpu.WGPULoadOp_Clear),
        .storeOp = @intCast(wgpu.WGPUStoreOp_Store),
        .clearValue = .{ .r = 0.05, .g = 0.06, .b = 0.09, .a = 1.0 },
    };
    const pass_desc = wgpu.WGPURenderPassDescriptor{ .colorAttachmentCount = 1, .colorAttachments = &color };
    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return;

    if (rect) |rr| {
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
        wgpu.wgpuRenderPassEncoderSetScissorRect(pass, @intFromFloat(rr.x), @intFromFloat(rr.y), @intFromFloat(rr.w), @intFromFloat(rr.h));
        // full-screen triangle, clipped to the box
        wgpu.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
    }

    wgpu.wgpuRenderPassEncoderEnd(pass);
    wgpu.wgpuRenderPassEncoderRelease(pass);

    const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
    defer wgpu.wgpuCommandBufferRelease(cmd);

    const cmds = [_]wgpu.WGPUCommandBuffer{cmd};
    wgpu.wgpuQueueSubmit(queue, cmds.len, &cmds);
    _ = wgpu.wgpuSurfacePresent(surface);
}

// --- IPC Thread: wake the GLFW loop on each FrameReady ---
fn controlLoop(control: std.Io.net.Stream, io: std.Io) void {
    while (true) {
        var msg: protocol.MsgHeader = undefined;
        const bytes = std.mem.asBytes(&msg);
        var got: usize = 0;

        while (got < bytes.len) {
            var bufs: [1][]u8 = .{bytes[got..]};
            const n = control.read(io, &bufs) catch |err| {
                std.debug.print("IPC: control read failed: {s}\n", .{@errorName(err)});
                return;
            };

            if (n == 0) {
                std.debug.print("IPC: control channel closed\n", .{});
                return;
            }

            got += n;
        }

        switch (@as(protocol.MsgKind, @enumFromInt(msg.kind))) {
            .frame_ready => glfw.glfwPostEmptyEvent(),
            else => std.debug.print("IPC: unexpected message kind={d}\n", .{msg.kind}),
        }
    }
}

pub fn main(init: std.process.Init) !void {
    if (glfw.glfwInit() == glfw.GLFW_FALSE) {
        std.debug.print("Failed to initialize glfw", .{});
        return error.GlfwInitFailed;
    }
    defer glfw.glfwTerminate();

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);

    const window = glfw.glfwCreateWindow(1024, 768, "Cara", null, null) orelse {
        std.debug.print("Failed to create window\n", .{});
        return error.WindowCreationFailed;
    };
    defer glfw.glfwDestroyWindow(window);

    std.debug.print("Cara host started\n", .{});

    // --- GPU: instance ---
    const v = wgpu.wgpuGetVersion();
    std.debug.print("HOST: wgpu-native v{d}.{d}.{d}.{d}\n", .{ (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF });

    const instance = wgpu.wgpuCreateInstance(null) orelse {
        std.debug.print("HOST: wgpuCreateInstance failed\n", .{});
        return error.WgpuInstanceFailed;
    };
    defer wgpu.wgpuInstanceRelease(instance);

    // --- GPU: Metal surface on the GLFW window ---
    const ns_window = glfwGetCocoaWindow(window) orelse return error.NoCocoaWindow;
    const metal_layer = metalLayerForWindow(ns_window) orelse return error.NoMetalLayer;

    var metal_source = wgpu.WGPUSurfaceSourceMetalLayer{
        // next defaults null
        .chain = .{ .sType = @intCast(wgpu.WGPUSType_SurfaceSourceMetalLayer) },
        .layer = metal_layer,
    };

    const surface_desc = wgpu.WGPUSurfaceDescriptor{
        // label defaults empty
        .nextInChain = &metal_source.chain,
    };

    const surface = wgpu.wgpuInstanceCreateSurface(instance, &surface_desc) orelse return error.SurfaceFailed;
    defer wgpu.wgpuSurfaceRelease(surface);

    std.debug.print("HOST: wgpu Metal surface created\n", .{});

    // --- GPU: adapter -> device -> queue ---
    var areq = AdapterReq{};
    const adapter_opts = wgpu.WGPURequestAdapterOptions{ .compatibleSurface = surface };
    _ = wgpu.wgpuInstanceRequestAdapter(instance, &adapter_opts, .{
        .mode = @intCast(wgpu.WGPUCallbackMode_AllowProcessEvents),
        .callback = &onAdapter,
        .userdata1 = &areq,
    });

    if (!areq.done) wgpu.wgpuInstanceProcessEvents(instance);

    const adapter = areq.adapter orelse return error.NoAdapter;
    defer wgpu.wgpuAdapterRelease(adapter);

    var dreq = DeviceReq{};
    const device_desc = wgpu.WGPUDeviceDescriptor{};
    _ = wgpu.wgpuAdapterRequestDevice(adapter, &device_desc, .{
        .mode = @intCast(wgpu.WGPUCallbackMode_AllowProcessEvents),
        .callback = &onDevice,
        .userdata1 = &dreq,
    });

    if (!dreq.done) wgpu.wgpuInstanceProcessEvents(instance);
    const device = dreq.device orelse return error.NoDevice;
    defer wgpu.wgpuDeviceRelease(device);

    const queue = wgpu.wgpuDeviceGetQueue(device);
    defer wgpu.wgpuQueueRelease(queue);

    // --- GPU: configure the surface to the framebuffer size ---
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;

    glfw.glfwGetFramebufferSize(window, &fb_w, &fb_h);

    const config = wgpu.WGPUSurfaceConfiguration{
        .device = device,
        .format = @intCast(wgpu.WGPUTextureFormat_BGRA8Unorm),
        .usage = wgpu.WGPUTextureUsage_RenderAttachment,
        .width = @intCast(fb_w),
        .height = @intCast(fb_h),
        .presentMode = @intCast(wgpu.WGPUPresentMode_Fifo),
        .alphaMode = @intCast(wgpu.WGPUCompositeAlphaMode_Auto),
    };

    wgpu.wgpuSurfaceConfigure(surface, &config);

    std.debug.print("HOST: adapter+device+queue ready, surface configured {d}x{d}\n", .{ config.width, config.height });

    // --- GPU: rectangle pipeline ---
    const rect_pipeline = createRectPipeline(device) orelse return;
    defer wgpu.wgpuRenderPipelineRelease(rect_pipeline);

    // --- Shared memory ring region ---
    var name_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintSentinel(&name_buf, "/cara-shm-{d}", .{std.c.getpid()}, 0);
    _ = std.c.shm_unlink(shm_name.ptr);

    const oflags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
    const fd = std.c.shm_open(shm_name.ptr, @bitCast(oflags), @as(c_uint, 0o600));

    if (fd < 0) {
        const errno_val: c_int = std.c._errno().*;
        std.debug.print("HOST: shm_open failed, ERRNO:{d}\n", .{errno_val});
        return error.ShmOpenFailed;
    }

    // Teardown on any exit from here - including error returns below.
    defer _ = std.c.shm_unlink(shm_name.ptr);

    if (std.c.ftruncate(fd, ring.region_size) != 0) {
        const errno_val: c_int = std.c._errno().*;
        std.debug.print("HOST: ftruncate failed, ERRNO={d}\n", .{errno_val});
        return error.FtruncateFailed;
    }

    const mapping = try std.posix.mmap(null, ring.region_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(mapping);

    const header: *ring.Header = @ptrCast(@alignCast(mapping.ptr));
    header.magic = ring.magic;
    header.version = ring.version;
    header.head = 0;
    header.tail = 0;
    std.debug.print("HOST: created {s}, header magic=0x{X} version={d}\n", .{ shm_name, header.magic, header.version });

    // --- Control channel: a named Unix socket (std.Io.net) ---
    var sock_buf: [64]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&sock_buf, "/tmp/cara-sock-{d}", .{std.c.getpid()});

    // Self-heal a stale socket from a prior crash (FileNotFound is the normal case).
    std.Io.Dir.deleteFileAbsolute(init.io, sock_path) catch {};

    const uaddr = try net.UnixAddress.init(sock_path);
    var server = try uaddr.listen(init.io, .{});
    defer {
        server.deinit(init.io);
        std.Io.Dir.deleteFileAbsolute(init.io, sock_path) catch {};
    }

    // --- Spawn renderer engine (shm_name + socket pth) ---
    spawnRenderer(init.io, init.gpa, shm_name, sock_path) catch |err| {
        std.debug.print("Failed to spawn renderer: {s}\n", .{@errorName(err)});
        return err;
    };

    // Block until the renderer connects back on the control channel.
    const control = try server.accept(init.io);
    defer control.close(init.io);

    std.debug.print("HOST: control channel connected\n", .{});

    // --- Consumer: drain the frame the renderer published ---
    const r = ring.Ring.init(mapping);

    // --- IPC thread + render loop ---
    const ipc = try std.Thread.spawn(.{}, controlLoop, .{ control, init.io });

    // First frame, so the window shows immediately
    var current_rect: ?draw.DrawRect = null;
    paint(surface, device, queue, rect_pipeline, current_rect);

    // Wakes on OS events and on FrameReady (posted by the IPC thread).
    // On each wake, drain whatever the renderer published - a no-op if the ring is empty
    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        glfw.glfwWaitEvents();

        if (r.reader()) |frame| {
            var rd = frame;

            while (rd.next()) |rec| {
                switch (@as(draw.DrawTag, @enumFromInt(rec.tag))) {
                    .rect => {
                        if (rec.bytes.len != @sizeOf(draw.DrawRect)) {
                            std.debug.print("HOST: malformed DrawRect ({d} bytes)\n", .{rec.bytes.len});
                            continue;
                        }

                        const cmd: *const draw.DrawRect = @ptrCast(@alignCast(rec.bytes.ptr));
                        current_rect = cmd.*;
                        std.debug.print("HOST: DrawRect x={d} y={d} w={d} h={d} rgba=0x{X}\n", .{ cmd.x, cmd.y, cmd.w, cmd.h, cmd.rgba });
                    },
                    else => std.debug.print("HOST: unknown command tag={d} ({d} bytes)\n", .{ rec.tag, rec.bytes.len }),
                }
            }

            rd.commit();
        }

        // Repaint each wake
        paint(surface, device, queue, rect_pipeline, current_rect);
    }

    // Window closing: unblock the IPC thread's blocking read, then join it.
    control.shutdown(init.io, .both) catch {};
    ipc.join();
}

fn spawnRenderer(io: std.Io, gpa: std.mem.Allocator, shm_name: [:0]const u8, sock_pth: []const u8) !void {
    const self_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(self_dir);

    const renderer_path = try std.fs.path.join(gpa, &.{ self_dir, "cara-renderer" });
    defer gpa.free(renderer_path);

    const argv = [_][]const u8{ renderer_path, shm_name, sock_pth };
    _ = try std.process.spawn(io, .{ .argv = &argv });
}
