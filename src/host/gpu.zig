const std = @import("std");
const glfw = @import("glfw");
const wgpu = @import("wgpu");
const draw = @import("draw");

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

const MapState = struct { done: bool = false };

fn onMap(status: wgpu.WGPUMapAsyncStatus, message: wgpu.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = status;
    _ = message;
    _ = ud2;

    const s: *MapState = @ptrCast(@alignCast(ud1));
    s.done = true;
}

// --- GPU: rectangle pipeline ---
// Multi-line string
const rect_wgsl =
    \\@group(0) @binding(0) var<uniform> u_color: vec4<f32>;
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    \\    var p = array<vec2<f32>, 3>(
    \\        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0)
    \\    );
    \\    return vec4<f32>(p[i], 0.0, 1.0);
    \\}
    \\struct FsOut {
    \\    @location(0) color: vec4<f32>,
    \\    @location(1) id: u32,
    \\}
    \\@fragment fn fs() -> FsOut {
    \\    return FsOut(u_color, 1u); // entity id 1 (the single rect); background = 0
    \\}
;

const glyph_wgsl =
    \\struct Uniforms { viewport: vec2<f32>, color: vec4<f32>, }
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@group(0) @binding(1) var atlas_tex: texture_2d<f32>;
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) texel: vec2<f32>, }
    \\@vertex fn vs(
    \\    @builtin(vertex_index) vi: u32,
    \\    @location(0) screen: vec2<f32>,
    \\    @location(1) atlas_xy: vec2<f32>,
    \\    @location(2) atlas_wh: vec2<f32>,
    \\) -> VsOut {
    \\    var corner = array<vec2<f32>, 6>(
    \\        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
    \\        vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0),
    \\    );
    \\    let c = corner[vi];
    \\    let pixel = screen + c * atlas_wh;
    \\    let clip = vec2<f32>(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0);
    \\    var out: VsOut;
    \\    out.pos = vec4<f32>(clip, 0.0, 1.0);
    \\    out.texel = atlas_xy + c * atlas_wh;
    \\    return out;
    \\}
    \\struct FsOut { @location(0) color: vec4<f32>, @location(1) id: u32, }
    \\@fragment fn fs(in: VsOut) -> FsOut {
    \\    let cov = textureLoad(atlas_tex, vec2<i32>(in.texel), 0).r;
    \\    return FsOut(vec4<f32>(u.color.rgb, cov), 0u);
    \\}
;

fn sv(s: []const u8) wgpu.WGPUStringView {
    return .{
        .data = s.ptr,
        .length = s.len,
    };
}

const RectPainter = struct {
    pipeline: wgpu.WGPURenderPipeline,
    buffer: wgpu.WGPUBuffer,
    bind_group: wgpu.WGPUBindGroup,
};

const GlyphInstance = extern struct {
    screen_x: f32,
    screen_y: f32,
    atlas_x: f32,
    atlas_y: f32,
    atlas_w: f32,
    atlas_h: f32,
};

// = 24
const glyph_instance_size = @sizeOf(GlyphInstance);
const max_glyphs = 256;

const GlyphPainter = struct {
    pipeline: wgpu.WGPURenderPipeline,
    uniforms: wgpu.WGPUBuffer,
    instances: wgpu.WGPUBuffer,
    bind_group: wgpu.WGPUBindGroup,
};

fn createGlyphPainter(device: wgpu.WGPUDevice, atlas_view: wgpu.WGPUTextureView) ?GlyphPainter {
    var wgsl = wgpu.WGPUShaderSourceWGSL{ .chain = .{ .sType = @intCast(wgpu.WGPUSType_ShaderSourceWGSL) }, .code = sv(glyph_wgsl) };
    const sm_desc = wgpu.WGPUShaderModuleDescriptor{ .nextInChain = &wgsl.chain };

    const module = wgpu.wgpuDeviceCreateShaderModule(device, &sm_desc) orelse return null;
    defer wgpu.wgpuShaderModuleRelease(module);

    const attrs = [_]wgpu.WGPUVertexAttribute{
        .{ .format = @intCast(wgpu.WGPUVertexFormat_Float32x2), .offset = 0, .shaderLocation = 0 },
        .{ .format = @intCast(wgpu.WGPUVertexFormat_Float32x2), .offset = 8, .shaderLocation = 1 },
        .{ .format = @intCast(wgpu.WGPUVertexFormat_Float32x2), .offset = 16, .shaderLocation = 2 },
    };

    const vbufs = [_]wgpu.WGPUVertexBufferLayout{
        .{
            .stepMode = @intCast(wgpu.WGPUVertexStepMode_Instance),
            .arrayStride = glyph_instance_size,
            .attributeCount = attrs.len,
            .attributes = &attrs,
        },
    };

    const glyph_blend = wgpu.WGPUBlendState{
        .color = .{
            .operation = @intCast(wgpu.WGPUBlendOperation_Add),
            .srcFactor = @intCast(wgpu.WGPUBlendFactor_SrcAlpha),
            .dstFactor = @intCast(wgpu.WGPUBlendFactor_OneMinusSrcAlpha),
        },
        .alpha = .{
            .operation = @intCast(wgpu.WGPUBlendOperation_Add),
            .srcFactor = @intCast(wgpu.WGPUBlendFactor_One),
            .dstFactor = @intCast(wgpu.WGPUBlendFactor_OneMinusSrcAlpha),
        },
    };

    const targets = [_]wgpu.WGPUColorTargetState{
        .{ .format = @intCast(wgpu.WGPUTextureFormat_BGRA8Unorm), .blend = &glyph_blend, .writeMask = wgpu.WGPUColorWriteMask_All },
        .{ .format = @intCast(wgpu.WGPUTextureFormat_R32Uint), .writeMask = wgpu.WGPUColorWriteMask_All },
    };

    const fragment = wgpu.WGPUFragmentState{ .module = module, .entryPoint = sv("fs"), .targetCount = 2, .targets = &targets };

    const desc = wgpu.WGPURenderPipelineDescriptor{
        .vertex = .{ .module = module, .entryPoint = sv("vs"), .bufferCount = 1, .buffers = &vbufs },
        .primitive = .{ .topology = @intCast(wgpu.WGPUPrimitiveTopology_TriangleList), .frontFace = @intCast(wgpu.WGPUFrontFace_CCW), .cullMode = @intCast(wgpu.WGPUCullMode_None) },
        .multisample = .{ .count = 1, .mask = 0xFFFF_FFFF },
        .fragment = &fragment,
    };

    const pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &desc) orelse return null;

    const ub_desc = wgpu.WGPUBufferDescriptor{ .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst, .size = 32 };

    const uniforms = wgpu.wgpuDeviceCreateBuffer(device, &ub_desc) orelse return null;

    const ib_desc = wgpu.WGPUBufferDescriptor{ .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst, .size = max_glyphs * glyph_instance_size };
    const instances = wgpu.wgpuDeviceCreateBuffer(device, &ib_desc) orelse return null;

    const bgl = wgpu.wgpuRenderPipelineGetBindGroupLayout(pipeline, 0) orelse return null;
    defer wgpu.wgpuBindGroupLayoutRelease(bgl);

    const entries = [_]wgpu.WGPUBindGroupEntry{
        .{ .binding = 0, .buffer = uniforms, .size = 32 },
        .{ .binding = 1, .textureView = atlas_view },
    };

    const bg_desc = wgpu.WGPUBindGroupDescriptor{ .layout = bgl, .entryCount = 2, .entries = &entries };

    const bind_group = wgpu.wgpuDeviceCreateBindGroup(device, &bg_desc) orelse return null;

    return .{
        .pipeline = pipeline,
        .uniforms = uniforms,
        .instances = instances,
        .bind_group = bind_group,
    };
}

fn createRectPainter(device: wgpu.WGPUDevice) ?RectPainter {
    var wgsl = wgpu.WGPUShaderSourceWGSL{
        .chain = .{ .sType = @intCast(wgpu.WGPUSType_ShaderSourceWGSL) },
        .code = sv(rect_wgsl),
    };
    const sm_desc = wgpu.WGPUShaderModuleDescriptor{ .nextInChain = &wgsl.chain };
    const module = wgpu.wgpuDeviceCreateShaderModule(device, &sm_desc) orelse return null;
    defer wgpu.wgpuShaderModuleRelease(module);

    const targets = [_]wgpu.WGPUColorTargetState{
        .{ .format = @intCast(wgpu.WGPUTextureFormat_BGRA8Unorm), .writeMask = wgpu.WGPUColorWriteMask_All },
        .{ .format = @intCast(wgpu.WGPUTextureFormat_R32Uint), .writeMask = wgpu.WGPUColorWriteMask_All },
    };

    const fragment = wgpu.WGPUFragmentState{
        .module = module,
        .entryPoint = sv("fs"),
        .targetCount = 2,
        .targets = &targets,
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

    const pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &desc) orelse return null;

    // 16-byte uniform buffer for the color (vec4<f32>)
    const buf_desc = wgpu.WGPUBufferDescriptor{
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .size = 16,
    };

    const buffer = wgpu.wgpuDeviceCreateBuffer(device, &buf_desc) orelse return null;

    // Bind the buffer against the pipline's auto-generated group(0) layout
    const bgl = wgpu.wgpuRenderPipelineGetBindGroupLayout(pipeline, 0) orelse return null;
    defer wgpu.wgpuBindGroupLayoutRelease(bgl);

    const entry = wgpu.WGPUBindGroupEntry{ .binding = 0, .buffer = buffer, .size = 16 };

    const bg_desc = wgpu.WGPUBindGroupDescriptor{
        .layout = bgl,
        .entryCount = 1,
        .entries = &entry,
    };

    const bind_group = wgpu.wgpuDeviceCreateBindGroup(device, &bg_desc) orelse return null;

    return .{ .pipeline = pipeline, .buffer = buffer, .bind_group = bind_group };
}

// --- The Public GPU Context ---
pub const Gpu = struct {
    instance: wgpu.WGPUInstance,
    surface: wgpu.WGPUSurface,
    adapter: wgpu.WGPUAdapter,
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,
    painter: RectPainter,
    id_texture: wgpu.WGPUTexture,
    id_view: wgpu.WGPUTextureView,
    readback: wgpu.WGPUBuffer,
    atlas_texture: wgpu.WGPUTexture,
    atlas_view: wgpu.WGPUTextureView,
    glyph: GlyphPainter,
    fb_w: u32,
    fb_h: u32,

    pub const Error = error{ Instance, NoCocoaWindow, NoMetalLayer, Surface, Adapter, Device, Pipeline, IdTexture, Readback, AtlasTexture, GlyphPipeline };

    pub fn init(window: *glfw.GLFWwindow) Error!Gpu {
        const instance = wgpu.wgpuCreateInstance(null) orelse return error.Instance;
        errdefer wgpu.wgpuInstanceRelease(instance);

        const ns_window = glfwGetCocoaWindow(window) orelse return error.NoCocoaWindow;
        const metal_layer = metalLayerForWindow(ns_window) orelse return error.NoMetalLayer;
        var metal_source = wgpu.WGPUSurfaceSourceMetalLayer{
            .chain = .{ .sType = @intCast(wgpu.WGPUSType_SurfaceSourceMetalLayer) },
            .layer = metal_layer,
        };

        const surface_desc = wgpu.WGPUSurfaceDescriptor{
            .nextInChain = &metal_source.chain,
        };
        const surface = wgpu.wgpuInstanceCreateSurface(instance, &surface_desc) orelse return error.Surface;
        errdefer wgpu.wgpuSurfaceRelease(surface);

        var areq = AdapterReq{};
        const adapter_opts = wgpu.WGPURequestAdapterOptions{
            .compatibleSurface = surface,
        };
        _ = wgpu.wgpuInstanceRequestAdapter(instance, &adapter_opts, .{
            .mode = @intCast(wgpu.WGPUCallbackMode_AllowProcessEvents),
            .callback = &onAdapter,
            .userdata1 = &areq,
        });

        if (!areq.done) wgpu.wgpuInstanceProcessEvents(instance);

        const adapter = areq.adapter orelse return error.Adapter;
        errdefer wgpu.wgpuAdapterRelease(adapter);

        var dreq = DeviceReq{};
        const device_desc = wgpu.WGPUDeviceDescriptor{};
        _ = wgpu.wgpuAdapterRequestDevice(adapter, &device_desc, .{
            .mode = @intCast(wgpu.WGPUCallbackMode_AllowProcessEvents),
            .callback = &onDevice,
            .userdata1 = &dreq,
        });

        if (!dreq.done) wgpu.wgpuInstanceProcessEvents(instance);

        const device = dreq.device orelse return error.Device;
        errdefer wgpu.wgpuDeviceRelease(device);

        const queue = wgpu.wgpuDeviceGetQueue(device);
        errdefer wgpu.wgpuQueueRelease(queue);

        const painter = createRectPainter(device) orelse return error.Pipeline;
        errdefer {
            wgpu.wgpuBindGroupRelease(painter.bind_group);
            wgpu.wgpuBufferRelease(painter.buffer);
            wgpu.wgpuRenderPipelineRelease(painter.pipeline);
        }

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

        // Parallel ID buffer: one entity id per pixel, read on input
        const id_desc = wgpu.WGPUTextureDescriptor{
            .usage = wgpu.WGPUTextureUsage_RenderAttachment | wgpu.WGPUTextureUsage_CopySrc,
            .dimension = @intCast(wgpu.WGPUTextureDimension_2D),
            .size = .{ .width = @intCast(fb_w), .height = @intCast(fb_h), .depthOrArrayLayers = 1 },
            .format = @intCast(wgpu.WGPUTextureFormat_R32Uint),
            .mipLevelCount = 1,
            .sampleCount = 1,
        };
        const id_texture = wgpu.wgpuDeviceCreateTexture(device, &id_desc) orelse return error.IdTexture;
        errdefer wgpu.wgpuTextureRelease(id_texture);

        const id_view = wgpu.wgpuTextureCreateView(id_texture, null) orelse return error.IdTexture;
        errdefer wgpu.wgpuTextureViewRelease(id_view);

        const rb_desc = wgpu.WGPUBufferDescriptor{
            .usage = wgpu.WGPUBufferUsage_MapRead | wgpu.WGPUBufferUsage_CopyDst,
            .size = 256,
        };
        const readback = wgpu.wgpuDeviceCreateBuffer(device, &rb_desc) orelse return error.Readback;
        errdefer wgpu.wgpuBufferRelease(readback);

        // Glyph atlas: R8 coverage, written as glyphs stream in,
        // sampled by the GlyphPainter 1024x1024 matches the renderer's packer
        const atlas_desc = wgpu.WGPUTextureDescriptor{
            .usage = wgpu.WGPUTextureUsage_TextureBinding | wgpu.WGPUTextureUsage_CopyDst,
            .dimension = @intCast(wgpu.WGPUTextureDimension_2D),
            .size = .{ .width = 1024, .height = 1024, .depthOrArrayLayers = 1 },
            .format = @intCast(wgpu.WGPUTextureFormat_R8Unorm),
            .mipLevelCount = 1,
            .sampleCount = 1,
        };
        const atlas_texture = wgpu.wgpuDeviceCreateTexture(device, &atlas_desc) orelse return error.AtlasTexture;
        errdefer wgpu.wgpuTextureRelease(atlas_texture);

        const atlas_view = wgpu.wgpuTextureCreateView(atlas_texture, null) orelse return error.AtlasTexture;
        errdefer wgpu.wgpuTextureViewRelease(atlas_view);

        const glyph = createGlyphPainter(device, atlas_view) orelse return error.GlyphPipeline;
        errdefer {
            wgpu.wgpuBindGroupRelease(glyph.bind_group);
            wgpu.wgpuBufferRelease(glyph.instances);
            wgpu.wgpuBufferRelease(glyph.uniforms);
            wgpu.wgpuRenderPipelineRelease(glyph.pipeline);
        }

        std.debug.print("HOST: gpu ready ({d}x{d}, +id buffer)\n", .{ fb_w, fb_h });

        return .{
            .instance = instance,
            .surface = surface,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .painter = painter,
            .id_texture = id_texture,
            .id_view = id_view,
            .readback = readback,
            .atlas_texture = atlas_texture,
            .atlas_view = atlas_view,
            .glyph = glyph,
            .fb_w = @intCast(fb_w),
            .fb_h = @intCast(fb_h),
        };
    }

    pub fn deinit(self: *Gpu) void {
        wgpu.wgpuTextureViewRelease(self.id_view);
        wgpu.wgpuTextureRelease(self.id_texture);
        wgpu.wgpuBindGroupRelease(self.painter.bind_group);
        wgpu.wgpuBufferRelease(self.painter.buffer);
        wgpu.wgpuRenderPipelineRelease(self.painter.pipeline);
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuDeviceRelease(self.device);
        wgpu.wgpuAdapterRelease(self.adapter);
        wgpu.wgpuSurfaceRelease(self.surface);
        wgpu.wgpuInstanceRelease(self.instance);
        wgpu.wgpuBufferRelease(self.readback);
        wgpu.wgpuTextureRelease(self.atlas_texture);
        wgpu.wgpuBindGroupRelease(self.glyph.bind_group);
        wgpu.wgpuBufferRelease(self.glyph.instances);
        wgpu.wgpuBufferRelease(self.glyph.uniforms);
        wgpu.wgpuRenderPipelineRelease(self.glyph.pipeline);
        wgpu.wgpuTextureViewRelease(self.atlas_view);
    }

    // --- per-frame paint: clear, then the rect (scissor-clipped) ---
    // * Returns true if it presented; false if the surface had no drawable yet
    // helps the caller to retry
    pub fn paint(self: *Gpu, rect: ?draw.DrawRect, glyphs: []const draw.PackedGlyph, text_rgba: u32) bool {
        var st: wgpu.WGPUSurfaceTexture = undefined;
        wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &st);

        const texture = st.texture orelse return false;
        defer wgpu.wgpuTextureRelease(texture);

        const view = wgpu.wgpuTextureCreateView(texture, null) orelse return false;
        defer wgpu.wgpuTextureViewRelease(view);

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return false;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        const attachments = [_]wgpu.WGPURenderPassColorAttachment{
            .{
                // 0: visible color (the surface), opaque black
                .view = view,
                .depthSlice = @intCast(wgpu.WGPU_DEPTH_SLICE_UNDEFINED),
                .loadOp = @intCast(wgpu.WGPULoadOp_Clear),
                .storeOp = @intCast(wgpu.WGPUStoreOp_Store),
                .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            },
            .{
                // 1: entity id (R32Uint), cleared to 0 = "no entity"
                .view = self.id_view,
                .depthSlice = @intCast(wgpu.WGPU_DEPTH_SLICE_UNDEFINED),
                .loadOp = @intCast(wgpu.WGPULoadOp_Clear),
                .storeOp = @intCast(wgpu.WGPUStoreOp_Store),
                .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        };

        const pass_desc = wgpu.WGPURenderPassDescriptor{ .colorAttachmentCount = 2, .colorAttachments = &attachments };
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return false;

        if (rect) |rr| {
            const rgba = rr.rgba;
            const rgba_f = [4]f32{
                @as(f32, @floatFromInt((rgba >> 24) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((rgba >> 16) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((rgba >> 8) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt(rgba & 0xFF)) / 255.0,
            };

            wgpu.wgpuQueueWriteBuffer(self.queue, self.painter.buffer, 0, &rgba_f, @sizeOf(@TypeOf(rgba_f)));

            wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.painter.pipeline);
            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.painter.bind_group, 0, null);
            wgpu.wgpuRenderPassEncoderSetScissorRect(pass, @intFromFloat(rr.x), @intFromFloat(rr.y), @intFromFloat(rr.w), @intFromFloat(rr.h));
            wgpu.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        }

        if (glyphs.len > 0) {
            const cr: f32 = @floatFromInt((text_rgba >> 24) & 0xFF);
            const cg: f32 = @floatFromInt((text_rgba >> 16) & 0xFF);
            const cb: f32 = @floatFromInt((text_rgba >> 8) & 0xFF);
            const ca: f32 = @floatFromInt(text_rgba & 0xFF);
            const ubuf = [8]f32{ @floatFromInt(self.fb_w), @floatFromInt(self.fb_h), 0, 0, cr / 255.0, cg / 255.0, cb / 255.0, ca / 255.0 };

            wgpu.wgpuQueueWriteBuffer(self.queue, self.glyph.uniforms, 0, &ubuf, @sizeOf(@TypeOf(ubuf)));

            var insts: [max_glyphs]GlyphInstance = undefined;
            const n = @min(glyphs.len, insts.len);

            for (glyphs[0..n], 0..) |gl, i| {
                insts[i] = .{ .screen_x = gl.screen_x, .screen_y = gl.screen_y, .atlas_x = @floatFromInt(gl.atlas_x), .atlas_y = @floatFromInt(gl.atlas_y), .atlas_w = @floatFromInt(gl.atlas_w), .atlas_h = @floatFromInt(gl.atlas_h) };
            }

            wgpu.wgpuQueueWriteBuffer(self.queue, self.glyph.instances, 0, &insts, n * glyph_instance_size);
            wgpu.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, self.fb_w, self.fb_h);
            wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.glyph.pipeline);
            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.glyph.bind_group, 0, null);
            wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.glyph.instances, 0, n * glyph_instance_size);
            wgpu.wgpuRenderPassEncoderDraw(pass, 6, @intCast(n), 0, 0);
        }

        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);

        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse
            return false;
        defer wgpu.wgpuCommandBufferRelease(cmd);

        const cmds = [_]wgpu.WGPUCommandBuffer{cmd};
        wgpu.wgpuQueueSubmit(self.queue, cmds.len, &cmds);
        _ = wgpu.wgpuSurfacePresent(self.surface);
        return true;
    }

    pub fn hitTest(self: *Gpu, x: u32, y: u32) u32 {
        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return 0;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        const src = wgpu.WGPUTexelCopyTextureInfo{
            .texture = self.id_texture,
            .origin = .{ .x = x, .y = y, .z = 0 },
            .aspect = @intCast(wgpu.WGPUTextureAspect_All),
        };

        const dst = wgpu.WGPUTexelCopyBufferInfo{
            .layout = .{ .offset = 0, .bytesPerRow = 256, .rowsPerImage = 1 },
            .buffer = self.readback,
        };

        const extent = wgpu.WGPUExtent3D{ .width = 1, .height = 1, .depthOrArrayLayers = 1 };
        wgpu.wgpuCommandEncoderCopyTextureToBuffer(encoder, &src, &dst, &extent);

        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return 0;
        defer wgpu.wgpuCommandBufferRelease(cmd);

        const cmds = [_]wgpu.WGPUCommandBuffer{cmd};
        wgpu.wgpuQueueSubmit(self.queue, cmds.len, &cmds);

        var state = MapState{};
        _ = wgpu.wgpuBufferMapAsync(self.readback, wgpu.WGPUMapMode_Read, 0, 256, .{
            .mode = @intCast(wgpu.WGPUCallbackMode_AllowProcessEvents),
            .callback = &onMap,
            .userdata1 = &state,
        });

        while (!state.done) _ = wgpu.wgpuDevicePoll(self.device, 1, null);

        const ptr = wgpu.wgpuBufferGetConstMappedRange(self.readback, 0, 4) orelse return 0;
        const id = @as(*const u32, @ptrCast(@alignCast(ptr))).*;
        wgpu.wgpuBufferUnmap(self.readback);

        return id;
    }

    /// Upload one glyh's 8-bit coverage into the atlas at (x, y)
    /// Coverage is tightly packed (stride = w)
    /// writeTexture has no 256-byte row-alignment requirement
    /// unlike a buffer copy, so width is fine as bytesPerRow
    pub fn uploadGlyph(self: *Gpu, x: u32, y: u32, w: u32, h: u32, coverage: []const u8) void {
        if (w == 0 or h == 0) return;

        const dst = wgpu.WGPUTexelCopyTextureInfo{
            .texture = self.atlas_texture,
            .mipLevel = 0,
            .origin = .{ .x = x, .y = y, .z = 0 },
            .aspect = @intCast(wgpu.WGPUTextureAspect_All),
        };
        const layout = wgpu.struct_WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = w, .rowsPerImage = h };
        const extent = wgpu.WGPUExtent3D{ .width = w, .height = h, .depthOrArrayLayers = 1 };
        wgpu.wgpuQueueWriteTexture(self.queue, &dst, coverage.ptr, coverage.len, &layout, &extent);
    }
};
