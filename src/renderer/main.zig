const draw = @import("draw");
const protocol = @import("protocol");
const ring = @import("ring");
const std = @import("std");

// Dependent imports
const net = std.Io.net;

fn readExact(stream: std.Io.net.Stream, io: std.Io, dst: []u8) !void {
    var got: usize = 0;

    while (got < dst.len) {
        var bufs: [1][]u8 = .{dst[got..]};
        const n = try stream.read(io, &bufs);

        if (n == 0) return error.ChannelClosed;

        got += n;
    }
}

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

    const sock_path = it.next() orelse {
        std.debug.print("RENDERER: no sock_path in argv\n", .{});
        return error.MissingSockPath;
    };

    // Open the EXISTING region - no CREAT, the host already made it.
    const oflags: std.c.O = .{ .ACCMODE = .RDWR };
    const fd = std.c.shm_open(shm_name.ptr, @bitCast(oflags), @as(c_uint, 0));

    if (fd < 0) {
        std.debug.print("RENDERER: shm_open({s}) failed: {s}\n", .{ shm_name, @tagName(std.posix.errno(fd)) });
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

    const uaddr = try net.UnixAddress.init(sock_path);
    const control = try uaddr.connect(init.io);
    defer control.close(init.io);

    std.debug.print("RENDERER: control channel connected\n", .{});

    // --- Producer: write one frame of draw commands, then publish ---
    const r = ring.Ring.init(mapping);
    var w = r.writer();

    const rect = draw.DrawRect{ .x = 32, .y = 48, .w = 240, .h = 120, .rgba = 0x3B82F6FF };

    w.append(@intFromEnum(draw.DrawTag.rect), std.mem.asBytes(&rect)) catch |err| {
        std.debug.print("RENDERER: append failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // Publish the whole frame with one Release-store
    w.commit();

    std.debug.print("RENDERER: committed frame ({d}-byte DrawRect), head now {d}\n", .{ @sizeOf(draw.DrawRect), header.head });

    // --- Receive control messages from the host until it closes the channel ---
    std.debug.print("RENDERER: listening for input\n", .{});

    while (true) {
        var hdr: protocol.MsgHeader = undefined;

        readExact(control, init.io, std.mem.asBytes(&hdr)) catch break;

        switch (@as(protocol.MsgKind, @enumFromInt(hdr.kind))) {
            .input_event => {
                var ev: protocol.InputEvent = undefined;
                readExact(control, init.io, std.mem.asBytes(&ev)) catch break;

                std.debug.print("RENDERER: InputEventt kind={d} at ({d},{d})entity={d}\n", .{ ev.kind, ev.x, ev.y, ev.entity });
            },
            else => {
                std.debug.print("RENDERER: unexpected message kind={d} len={d}\n", .{ hdr.kind, hdr.len });
                break;
            },
        }
    }

    // Signal the host that a frame is ready
    const frame_ready = protocol.MsgHeader{ .kind = @intFromEnum(protocol.MsgKind.frame_ready), .len = 0 };

    var ctl_buf: [64]u8 = undefined;
    var cw = control.writer(init.io, &ctl_buf);

    cw.interface.writeAll(std.mem.asBytes(&frame_ready)) catch |err| {
        std.debug.print("RENDERER: FrameReady write failed: {s}\n", .{@errorName(err)});
    };

    cw.interface.flush() catch |err| {
        std.debug.print("RENDERER: FrameReady flush failed: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print("RENDERER: sent FrameReady\n", .{});
}
