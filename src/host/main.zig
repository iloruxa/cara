const draw = @import("draw");
const glfw = @import("glfw");
const protocol = @import("protocol");
const ring = @import("ring");
const std = @import("std");
const net = std.Io.net;
const Gpu = @import("gpu.zig").Gpu;

// --- Input: on left-click, hit-test the cursor against the ID buffer ---
fn onMouseButton(window: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;

    if (button != glfw.GLFW_MOUSE_BUTTON_LEFT or action != glfw.GLFW_PRESS) return;

    const g: *Gpu = @ptrCast(@alignCast(glfw.glfwGetWindowUserPointer(window)));

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

    const id = g.hitTest(px, py);

    std.debug.print("HOST: click ({d},{d}) -> entity {d}\n", .{ px, py, id });
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

    // --- GPU: surface + device + pipelin ---
    var gpu = try Gpu.init(window);
    defer gpu.deinit();

    glfw.glfwSetWindowUserPointer(window, &gpu);
    _ = glfw.glfwSetMouseButtonCallback(window, &onMouseButton);

    // --- Shared memory ring region ---
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

    const trunc = std.c.ftruncate(fd, ring.region_size);
    if (trunc != 0) {
        std.debug.print("HOST: ftruncate failed: {s}\n", .{@tagName(std.posix.errno(trunc))});
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

    // --- Control channel: named Unix socket (via std.Io.net) ---
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
    gpu.paint(current_rect);

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
        gpu.paint(current_rect);
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
