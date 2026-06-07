const draw = @import("draw");
const glfw = @import("glfw");
const ring = @import("ring");
const std = @import("std");

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

    // --- Shared memory region ---
    // Created here, owned by the host for the whole process lifetime,
    // torn down on exit. The rendere will map this same region by name.

    var name_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintSentinel(&name_buf, "/cara-shm-{d}", .{std.c.getpid()}, 0);

    // Clear any stale object a previously crashed run left under
    // this name. "Not found" is the normal case, so the result is ignored.
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

    // Spawn renderer engine
    spawnRenderer(init.io, init.gpa, shm_name) catch |err| {
        std.debug.print("Failed to spawn renderer: {s}\n", .{@errorName(err)});
        return err;
    };

    // --- Consumer: drain the frame the renderer published ---
    const r = ring.Ring.init(mapping);

    // TODO: Delete this busy-wait. Block on the IPC socket for
    // FrameReady, wake the GLFW loop via glfwPostEmptyEvent().
    // SCAFFOLD ONLY
    var frame: ?ring.Ring.Reader = null;
    var spins: u64 = 0;

    while (spins < 100_000_000_000) : (spins += 1) {
        frame = r.reader();

        if (frame != null) break;
    }

    // Drain loop
    if (frame) |*rd| {
        while (rd.next()) |rec| {
            switch (@as(draw.DrawTag, @enumFromInt(rec.tag))) {
                .rect => {
                    // Host validates the (sandboxed, untrusted) renderer's payload
                    // before trusting its shape.
                    if (rec.bytes.len != @sizeOf(draw.DrawRect)) {
                        std.debug.print("HOST: malformed DrawRect ({d} bytes)\n", .{rec.bytes.len});
                        continue;
                    }

                    // Decode in-place: no copy. Payload is 8-aligned by construction.
                    const cmd: *const draw.DrawRect = @ptrCast(@alignCast(rec.bytes.ptr));

                    std.debug.print("HOST: DrawRect x={d} y={d} w={d} h={d} rgba=0x{X}", .{ cmd.x, cmd.y, cmd.w, cmd.h, cmd.rbga });
                },

                else => std.debug.print("HOST: unknown command tag={d} ({d} bytes)\n", .{ rec.tag, rec.bytes.len }),
            }
        }

        rd.commit(); // release the whole frame with one Release-store
    } else {
        std.debug.print("HOST: timed out waiting for renderer to publish\n", .{});
    }

    // Window event loop
    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        glfw.glfwWaitEvents();
    }
}

fn spawnRenderer(io: std.Io, gpa: std.mem.Allocator, shm_name: [:0]const u8) !void {
    const self_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(self_dir);

    const renderer_path = try std.fs.path.join(gpa, &.{ self_dir, "cara-renderer" });
    defer gpa.free(renderer_path);

    const argv = [_][]const u8{ renderer_path, shm_name };
    _ = try std.process.spawn(io, .{ .argv = &argv });
}
