const draw = @import("draw");
const frame = @import("frame");
const glfw = @import("glfw");
const protocol = @import("protocol");
const std = @import("std");

// Module imports
const Gpu = @import("gpu.zig").Gpu;

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

        // Drain any payload: this thread only reacts to the envelope tag
        var remaining: usize = env.length;
        var skip: [256]u8 = undefined;

        while (remaining > 0) {
            const want = @min(remaining, skip.len);

            readFull(control, io, skip[0..want]) catch return;

            remaining -= want;
        }

        switch (@as(protocol.Tag, @enumFromInt(env.tag))) {
            .frame_ready => glfw.glfwPostEmptyEvent(),
            else => std.debug.print("IPC: unexpected tag={d}\n", .{env.tag}),
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

    // Teardown on any exit from here - including error returns below.
    defer _ = std.c.shm_unlink(shm_name.ptr);

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
    spawnRenderer(init.io, init.gpa, shm_name, sock_path) catch |err| {
        std.debug.print("Failed to spawn renderer: {s}\n", .{@errorName(err)});
        return err;
    };

    // Block until the renderer connects back on the control channel.
    const control = try server.accept(init.io);
    defer control.close(init.io);

    var click_ctx = ClickCtx{ .gpu = &gpu, .control = control, .io = init.io };

    glfw.glfwSetWindowUserPointer(window, &click_ctx);
    _ = glfw.glfwSetMouseButtonCallback(window, &onMouseButton);
    _ = glfw.glfwSetWindowRefreshCallback(window, &onWindowRefresh);
    _ = glfw.glfwSetFramebufferSizeCallback(window, &onFramebufferSize);
    std.debug.print("HOST: control channel connected\n", .{});

    // --- Consumer + IPC Thread + Event-driven render loop ---
    const frames = frame.Frames.init(region);
    var consumer = frames.consumer();

    // --- IPC thread + render loop ---
    const ipc = try std.Thread.spawn(.{}, controlLoop, .{ control, init.io });

    // The held display list.
    // needs_repaint starts true and is re-armed by expose/resize so the frame is (re)presented
    // once window is genuinely on screen, not just once as it appears
    var held: ?draw.DrawRect = null;

    // Wakes on OS events and on FrameReady (posted by the IPC thread).
    // We paint only when a new frame is taken
    // A coalesced wake with nothing new stays idle.
    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        glfw.glfwWaitEvents();

        // A newly published frame updates the held display list
        if (consumer.take()) |slot| {
            const fr = frame.parse(slot);
            click_ctx.frame_seq = fr.header.seq;

            var cmds = draw.Iterator{ .buf = fr.commands };

            while (cmds.next()) |cmd| {
                switch (cmd.tag) {
                    .rect => {
                        if (cmd.payload.len == @sizeOf(draw.DrawRect)) {
                            const r: *const draw.DrawRect = @ptrCast(@alignCast(cmd.payload.ptr));
                            held = r.*;
                        } else std.debug.print("HOST: malformed DrawRect ({d} bytes)\n", .{cmd.payload.len});
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
            if (gpu.paint(held)) {
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

fn spawnRenderer(io: std.Io, gpa: std.mem.Allocator, shm_name: [:0]const u8, sock_path: []const u8) !void {
    const self_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(self_dir);

    const renderer_path = try std.fs.path.join(gpa, &.{ self_dir, "cara-renderer" });
    defer gpa.free(renderer_path);

    const argv = [_][]const u8{ renderer_path, shm_name, sock_path };
    _ = try std.process.spawn(io, .{ .argv = &argv });
}
