const std = @import("std");
const glfw = @import("glfw");

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

    // Spawn renderer engine
    spawnRenderer(init.io, init.gpa) catch |err| {
        std.debug.print("Failed to spawn renderer: {s}\n", .{@errorName(err)});
        return err;
    };

    // shm: read-write
    try hostShmSelfTest();

    // Window event loop
    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        glfw.glfwPollEvents();
    }
}

fn spawnRenderer(io: std.Io, gpa: std.mem.Allocator) !void {
    const self_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(self_dir);

    const renderer_path = try std.fs.path.join(gpa, &.{ self_dir, "Cara-renderer" });
    defer gpa.free(renderer_path);

    const argv = [_][]const u8{renderer_path};
    _ = try std.process.spawn(io, .{ .argv = &argv });
}

fn hostShmSelfTest() !void {
    const shm_size = 4096;
    const magic: u32 = 0x43415241; // "CARA"

    // 1. A name unique to this process,  in the shm namespace.
    var name_buf: [64]u8 = undefined;
    const name_str = try std.fmt.bufPrintSentinel(&name_buf, "/cara-shm-{d}", .{std.c.getpid()}, 0);
    name_buf[name_str.len] = 0;
    const name: [:0]const u8 = name_buf[0..name_str.len :0];

    // 2. Create the shared-memory object: read-write, create if absent.
    const oflags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
    const fd = std.c.shm_open(name.ptr, @bitCast(oflags), @as(c_uint, 0o600));

    if (fd < 0) {
        const errno_val: c_int = std.c._errno().*;
        std.debug.print("HOST: shm_open failed, ERRNO={d}\n", .{errno_val});
        return error.ShmOpenFailed;
    }

    // 3. Give the region a size (shm objects tart at zero length).
    if (std.c.ftruncate(fd, shm_size) != 0) {
        const errno_val: c_int = std.c._errno().*;
        std.debug.print("HOST: ftruncate failed, ERRNO={d}\n", .{errno_val});
        return error.FtruncateFailed;
    }

    // 4. Map it read-write, shared, into our address space.
    const mapping = try std.posix.mmap(null, shm_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(mapping);

    // 5. Write the magic number, then read it straight back.
    const slot: *u32 = @ptrCast(@alignCast(mapping.ptr));
    slot.* = magic;
    const seen = slot.*;

    std.debug.print("HOST: wrote and read back 0x{X} via {s}\n", .{ seen, name });
}
