const std = @import("std");
const ring = @import("ring");

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
    const mapping = try std.posix.mmap(null, ring.region_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(mapping);

    // Overlay the shared header and validate it before trusting anything.
    const header: *ring.Header = @ptrCast(@alignCast(mapping.ptr));

    if (header.magic != ring.magic) {
        std.debug.print("RENDERER: bad magic 0x{X} (expected 0x{X})\n", .{ header.magic, ring.magic });
        return error.BadMagic;
    }

    if (header.version != ring.version) {
        std.debug.print("RENDERER: version mismatch {d} (expected {d})\n", .{ header.version, ring.version });
        return error.VersionMismatch;
    }

    std.debug.print("RENDERER: header OK - magic=0x{X} version={d} head={d} tail={d} via {s}\n", .{ header.magic, header.version, header.head, header.tail, shm_name });

    // --- Producer: write one record into the ring, then advance head ---
    const payload: [*]u8 = @as([*]u8, @ptrCast(mapping.ptr)) + ring.payload_offset;
    const message = "HELLO CARA";
    const size: u32 = @intCast(message.len);

    // Producer owns `head`. Acquire-load the consumer's `tail` to see free space
    const tail = @atomicLoad(u32, &header.tail, .acquire);
    const head = header.head; // Only the producer writes head, so a plain reaed is fine
    const used = head -% tail; // Wrapping subtraction
    const free = ring.payload_size - used; // plain: used <= payload_size

    if (free < size) {
        std.debug.print("RENDERER: not enough free space ({d} < {d})\n", .{ free, size });
        return error.RingFull;
    }

    // Write at head's position, then publish the advanced head with a Release store
    const idx = head % ring.payload_size;
    @memcpy(payload[0..message.len], message);
    @atomicStore(u32, &header.head, @intCast(message.len), .release);

    std.debug.print("RENDERER: wrote {d} bytes at idx={d}, published head={d} -> {d}\n", .{ size, idx, head, head +% size });
}
