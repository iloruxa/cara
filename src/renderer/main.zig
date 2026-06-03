const std = @import("std");

const shm_size = 4096;

pub fn main(init: std.process.Init) !void {
    std.debug.print("Cara renderer started\n", .{});

    // The host passed the shm name as argv[1].
    // Skip argv[0] (renderer process'es path)
    var it = init.minimal.args.iterate();
    _ = it.skip();

    const shm_name = it.next() orelse {
        std.debug.print("RENDERER: no shm_name in argv", .{});
        return error.MissingShmName;
    };

    // Open the EXISTING region - no CREAT, the host already made it.
    const oflags: std.c.O = .{ .ACCMODE = .RDWR };
    const fd = std.c.shm_open(shm_name.ptr, @bitCast(oflags), @as(c_uint, 0));

    if (fd < 0) {
        const errno_val: c_int = std.c._errno().*;
        std.debug.print("RENDERER: shm_open({s}) failed, ERRNO={d}\n", .{ shm_name, errno_val });
        return error.ShmOpenFailed;
    }

    // Map it - same size and flags the host used.
    const mapping = try std.posix.mmap(null, shm_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(mapping);

    // Read the magic number - from a process that never wrote it.
    const slot: *u32 = @ptrCast(@alignCast(mapping.ptr));
    const seen = slot.*;
    std.debug.print("RENDERER: sees 0x{X} via {s}\n", .{ seen, shm_name });
}
