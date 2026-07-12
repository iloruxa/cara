const draw = @import("draw");
const fdpass = @import("fdpass");
const frame = @import("frame");
const glfw = @import("glfw");
const protocol = @import("protocol");
const staging = @import("staging");
const std = @import("std");

// Module imports
const Gpu = @import("gpu.zig").Gpu;
const GlyphInstance = @import("gpu.zig").GlyphInstance;
const RectInstance = @import("gpu.zig").RectInstance;

// Dependent imports
const net = std.Io.net;

const ClickCtx = struct {
    gpu: *Gpu,
    control: net.Stream,
    io: std.Io,

    // seq of the frame currently on screen (for InputEvent)
    frame_seq: u32 = 0,

    // host's outgoing envelope counter
    send_seq: u32 = 0,

    // Set by expose/resize; loop re-presents the held frame
    needs_repaint: bool = true,
};

// --- Input: left-click -> hit-test -> InputEvent to the renderer ---
fn onMouseButton(window: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;

    if (button != glfw.GLFW_MOUSE_BUTTON_LEFT or action != glfw.GLFW_PRESS) return;

    const ctx: *ClickCtx = @ptrCast(@alignCast(glfw.glfwGetWindowUserPointer(window)));

    var cx: f64 = 0;
    var cy: f64 = 0;

    glfw.glfwGetCursorPos(window, &cx, &cy);

    if (cx < 0 or cy < 0) return;

    var ww: c_int = 0;
    var wh: c_int = 0;

    glfw.glfwGetWindowSize(window, &ww, &wh);

    var fw: c_int = 0;
    var fh: c_int = 0;

    glfw.glfwGetFramebufferSize(window, &fw, &fh);

    const px: u32 = @intFromFloat(cx * @as(f64, @floatFromInt(fw)) / @as(f64, @floatFromInt(ww)));
    const py: u32 = @intFromFloat(cy * @as(f64, @floatFromInt(fh)) / @as(f64, @floatFromInt(wh)));

    if (px >= @as(u32, @intCast(fw)) or py >= @as(u32, @intCast(fh))) return;

    const entity = ctx.gpu.hitTest(px, py);

    std.debug.print("HOST: click ({d},{d}) -> entity {d}\n", .{ px, py, entity });

    ctx.send_seq +%= 1;

    const ev = protocol.InputEvent{
        .kind = @intFromEnum(protocol.InputKind.mouse_down),
        .modifiers = 0,
        .x = @floatFromInt(px),
        .y = @floatFromInt(py),
        .hit_entity = entity,
        .frame_seq = ctx.frame_seq,
    };

    const env = protocol.Envelope{
        .tag = @intFromEnum(protocol.Tag.input_event),
        .flags = 0,
        .length = @sizeOf(protocol.InputEvent),
        .seq = ctx.send_seq,
    };

    var buf: [64]u8 = undefined;
    var cw = ctx.control.writer(ctx.io, &buf);

    cw.interface.writeAll(std.mem.asBytes(&env)) catch return;
    cw.interface.writeAll(std.mem.asBytes(&ev)) catch return;
    cw.interface.flush() catch return;
}

// --- Expose: the window was shown or uncovered, re-present the held frame
fn onWindowRefresh(window: ?*glfw.GLFWwindow) callconv(.c) void {
    const ctx: *ClickCtx = @ptrCast(@alignCast(glfw.glfwGetWindowUserPointer(window)));
    ctx.needs_repaint = true;
}

// --- Resize: marks a repaint ---
fn onFramebufferSize(window: ?*glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    _ = width;
    _ = height;

    const ctx: *ClickCtx = @ptrCast(@alignCast(glfw.glfwGetWindowUserPointer(window)));
    ctx.needs_repaint = true;
}

fn readFull(stream: net.Stream, io: std.Io, dst: []u8) !void {
    var got: usize = 0;

    while (got < dst.len) {
        var bufs: [1][]u8 = .{dst[got..]};
        const n = try stream.read(io, &bufs);

        if (n == 0) return error.ChannelClosed;

        got += n;
    }
}

// --- IPC Thread: wake the GLFW loop on each FrameReady ---
fn controlLoop(control: net.Stream, io: std.Io) void {
    while (true) {
        var env: protocol.Envelope = undefined;

        readFull(control, io, std.mem.asBytes(&env)) catch {
            std.debug.print("IPC: control channel closed\n", .{});
            return;
        };

        const tag: protocol.Tag = @enumFromInt(env.tag);

        // The renderer is hostile, reject out-of-subset tags and
        // absurd payload sizes before draining a byte
        // A violation means lost framing on the stream
        // so we cannot safely resync. Close the channel
        if (!protocol.rendererMaySend(tag)) {
            std.debug.print("IPC: closing an out-of-subset tag={d}\n", .{env.tag});
            return;
        }

        if (env.length > protocol.max_control_payload) {
            std.debug.print("IPC: closing on oversized payload len={d}\n", .{env.length});
            return;
        }

        // Drain any payload: this thread only reacts to the envelope tag
        var remaining: usize = env.length;
        var skip: [256]u8 = undefined;

        while (remaining > 0) {
            const want = @min(remaining, skip.len);

            readFull(control, io, skip[0..want]) catch return;

            remaining -= want;
        }

        switch (tag) {
            .frame_ready => glfw.glfwPostEmptyEvent(),
            else => std.debug.print("IPC: tag={d} in subset but not yet handled\n", .{env.tag}),
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

    // --- GPU: surface + device + pipelin ---
    var gpu = try Gpu.init(window);
    defer gpu.deinit();

    // --- Shared frame-slot region ---
    var name_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintSentinel(&name_buf, "/cara-shm-{d}", .{std.c.getpid()}, 0);
    _ = std.c.shm_unlink(shm_name.ptr);

    const oflags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
    const fd = std.c.shm_open(shm_name.ptr, @bitCast(oflags), @as(c_uint, 0o600));

    if (fd < 0) {
        std.debug.print("HOST: shm_open failed: {s}\n", .{@tagName(std.posix.errno(fd))});
        return error.ShmOpenFailed;
    }

    // Name dies here - the fd is the only capability, the renderer receives it
    // over the control channel, nothing ever opens this region by name
    _ = std.c.shm_unlink(shm_name.ptr);

    const trunc = std.c.ftruncate(fd, frame.region_size);
    if (trunc != 0) {
        std.debug.print("HOST: ftruncate failed: {s}\n", .{@tagName(std.posix.errno(trunc))});
        return error.FtruncateFailed;
    }

    const mapping = try std.posix.mmap(null, frame.region_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(mapping);

    const region: []align(frame.cache_line) u8 = mapping;
    frame.writeInitialHeader(region);
    std.debug.print("HOST: created {s} ({d} bytes)\n", .{ shm_name, frame.region_size });

    // --- Staging region (the atlas stream): a second shared region created and shared
    // like the frame region. Capacity must exceed one frame's worst-case glyph additions;
    // a fixed 8 MiB is ample for now (viewport derived sizing + Resize re-sizing will come later)
    // The host owns the value and passes it on
    // = 8 MiB, a power of two
    const staging_cap: u32 = 8 << 20;

    var staging_name_buf: [64]u8 = undefined;
    const staging_name = try std.fmt.bufPrintSentinel(&staging_name_buf, "/cara-staging-{d}", .{std.c.getpid()}, 0);
    _ = std.c.shm_unlink(staging_name.ptr);

    const staging_oflags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
    const staging_fd = std.c.shm_open(staging_name.ptr, @bitCast(staging_oflags), @as(c_uint, 0o600));

    if (staging_fd < 0) {
        std.debug.print("HOST: staging shm_open failed: {s}\n", .{@tagName(std.posix.errno(staging_fd))});
        return error.ShmOpenFailed;
    }

    // Name dies here - the fd is the only capability, the renderer receives it
    // over the control channel, nothing ever opens this region by name
    _ = std.c.shm_unlink(staging_name.ptr);

    if (std.c.ftruncate(staging_fd, @intCast(staging.regionSize(staging_cap))) != 0) {
        std.debug.print("HOST: staging ftruncate failed\n", .{});
        return error.FtruncateFailed;
    }

    const staging_map = try std.posix.mmap(null, staging.regionSize(staging_cap), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, staging_fd, 0);
    defer std.posix.munmap(staging_map);

    const staging_region: []align(staging.cache_line) u8 = staging_map;
    staging.writeInitialHeader(staging_region);
    std.debug.print("HOST: staging region {s} cap={d} ({d} bytes)\n", .{ staging_name, staging_cap, staging.regionSize(staging_cap) });

    // --- Control channel: named Unix socket ---
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
    spawnRenderer(init.io, init.gpa, sock_path, staging_cap) catch |err| {
        std.debug.print("Failed to spawn renderer: {s}\n", .{@errorName(err)});
        return err;
    };

    // Block until the renderer connects back on the control channel.
    const control = try server.accept(init.io);
    defer control.close(init.io);

    // The renderer opens noting by name. Its shared memory arrives as the first
    // two SCM_RIGHTS messages on this channel: frame region, then staging
    try fdpass.sendFd(control.socket.handle, fd);
    try fdpass.sendFd(control.socket.handle, staging_fd);

    var click_ctx = ClickCtx{ .gpu = &gpu, .control = control, .io = init.io };

    glfw.glfwSetWindowUserPointer(window, &click_ctx);
    _ = glfw.glfwSetMouseButtonCallback(window, &onMouseButton);
    _ = glfw.glfwSetWindowRefreshCallback(window, &onWindowRefresh);
    _ = glfw.glfwSetFramebufferSizeCallback(window, &onFramebufferSize);
    std.debug.print("HOST: control channel connected\n", .{});

    // --- Consumer + IPC Thread + Event-driven render loop ---
    const frames = frame.Frames.init(region);
    var consumer = frames.consumer();

    // Atlas-stream consumer + scratch for the largest glyph's coverage
    const atlas_region = staging.Staging.init(staging_region, staging_cap);
    var atlas_consumer = atlas_region.consumer();
    var glyph_cov: [256 * 256]u8 = undefined;

    // --- IPC thread + render loop ---
    const ipc = try std.Thread.spawn(.{}, controlLoop, .{ control, init.io });

    // The held display list.
    // needs_repaint starts true and is re-armed by expose/resize so the frame is (re)presented
    // once window is genuinely on screen, not just once as it appears
    var rect_instances: [1024]RectInstance = undefined;
    var rect_count: usize = 0;
    var glyph_instances: [4096]GlyphInstance = undefined;
    var gi_count: usize = 0;

    // Wakes on OS events and on FrameReady (posted by the IPC thread).
    // We paint only when a new frame is taken
    // A coalesced wake with nothing new stays idle.
    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        glfw.glfwWaitEvents();

        // A newly published frame updates the held display list
        if (consumer.take()) |slot| {
            const fr = frame.parse(slot);
            click_ctx.frame_seq = fr.header.seq;
            rect_count = 0;
            gi_count = 0;

            // Drain the atlas stream to head (atlas_head_required is the floor)
            while (atlas_consumer.pop(&glyph_cov) catch null) |drained| {
                gpu.uploadGlyph(drained.entry.atlas_x, drained.entry.atlas_y, drained.entry.width, drained.entry.height, drained.coverage);
            }

            var cmds = draw.Iterator{ .buf = fr.commands };

            while (cmds.next()) |cmd| {
                switch (cmd.tag) {
                    .rect => {
                        if (cmd.payload.len == @sizeOf(draw.DrawRect)) {
                            const r: *const draw.DrawRect = @ptrCast(@alignCast(cmd.payload.ptr));

                            if (rect_count < rect_instances.len) {
                                rect_instances[rect_count] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .rgba = r.rgba, .entity = r.entity };
                                rect_count += 1;
                            }
                        } else std.debug.print("HOST: malformed DrawRect ({d} bytes)\n", .{cmd.payload.len});
                    },
                    .text_run => {
                        if (draw.parseTextRun(cmd.payload)) |run| {
                            for (run.glyphs) |gl| {
                                if (gi_count == glyph_instances.len) break;

                                glyph_instances[gi_count] = .{
                                    .screen_x = gl.screen_x,
                                    .screen_y = gl.screen_y,
                                    .atlas_x = @floatFromInt(gl.atlas_x),
                                    .atlas_y = @floatFromInt(gl.atlas_y),
                                    .atlas_w = @floatFromInt(gl.atlas_w),
                                    .atlas_h = @floatFromInt(gl.atlas_h),
                                    .rgba = run.rgba,
                                    .entity = run.entity,
                                };

                                gi_count += 1;
                            }
                        } else std.debug.print("HOST: malformed text run\n", .{});
                    },
                    else => std.debug.print("HOST: unknown command tag={d} ({d} bytes)\n", .{ @intFromEnum(cmd.tag), cmd.payload.len }),
                }
            }

            click_ctx.needs_repaint = true;
            std.debug.print("HOST: took frame seq={d}\n", .{fr.header.seq});
        }

        // Paint on a new frame or an expose/resize
        // If the surface has no drawable yet (window still appearing -> Occluded),
        // keep the flag set and wake ourselves so we retry on the next pump,
        // until it is on screen
        if (click_ctx.needs_repaint) {
            if (gpu.paint(rect_instances[0..rect_count], glyph_instances[0..gi_count])) {
                click_ctx.needs_repaint = false;
            } else {
                glfw.glfwPostEmptyEvent();
            }
        }
    }

    // Window closing: unblock the IPC thread's blocking read, then join it.
    control.shutdown(init.io, .both) catch {};
    ipc.join();
}

fn spawnRenderer(io: std.Io, gpa: std.mem.Allocator, sock_path: []const u8, staging_cap: u32) !void {
    const self_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(self_dir);

    const renderer_path = try std.fs.path.join(gpa, &.{ self_dir, "cara-renderer" });
    defer gpa.free(renderer_path);

    var cap_buf: [16]u8 = undefined;
    const cap_str = try std.fmt.bufPrint(&cap_buf, "{d}", .{staging_cap});

    const argv = [_][]const u8{ renderer_path, sock_path, cap_str };
    _ = try std.process.spawn(io, .{ .argv = &argv });
}
