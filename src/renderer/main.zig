const atlas = @import("atlas.zig");
const draw = @import("draw");
const frame = @import("frame");
const raster = @import("raster.zig");
const protocol = @import("protocol");
const staging = @import("staging");
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

fn drain(stream: net.Stream, io: std.Io, length: u32) !void {
    var remaining: usize = length;
    var skip: [256]u8 = undefined;

    while (remaining > 0) {
        const want = @min(remaining, skip.len);

        try readExact(stream, io, skip[0..want]);

        remaining -= want;
    }
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("Cara renderer started\n", .{});

    // argv:
    // - [0] -> self
    // - [1] -> shm_name
    // - [2] -> sock_path
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

    const staging_name = it.next() orelse {
        std.debug.print("RENDERER: no staging_name in argv\n", .{});
        return error.MissingStagingName;
    };

    const staging_cap = blk: {
        const s = it.next() orelse {
            std.debug.print("RENDERER: no staging_cap in argv\n", .{});
            return error.MissingStagingCap;
        };

        break :blk try std.fmt.parseInt(u32, s, 10);
    };

    // Open the EXISTING region - no CREATE, the host already made it.
    // Open-by-name is known-temporary: Host pass the fd via SCM_RIGHTS
    const oflags: std.c.O = .{ .ACCMODE = .RDWR };
    const fd = std.c.shm_open(shm_name.ptr, @bitCast(oflags), @as(c_uint, 0));

    if (fd < 0) {
        std.debug.print("RENDERER: shm_open({s}) failed: {s}\n", .{ shm_name, @tagName(std.posix.errno(fd)) });
        return error.ShmOpenFailed;
    }

    // Map it - same size and flags the host used.
    const mapping = try std.posix.mmap(null, frame.region_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(mapping);

    // Validate the host-created region before trusting a byte
    const region: []align(frame.cache_line) u8 = mapping;
    frame.validate(region) catch |err| {
        std.debug.print("RENDERER: shared region invalid: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print("RENDERER: shared region OK via {s}\n", .{shm_name});

    // --- Map the staging region (the atlas stream) shared by the host ---
    const staging_oflags: std.c.O = .{ .ACCMODE = .RDWR };
    const staging_fd = std.c.shm_open(staging_name.ptr, @bitCast(staging_oflags), @as(c_uint, 0));

    if (staging_fd < 0) {
        std.debug.print("RENDERER: staging shm_open({s}) failed: {s}\n", .{ staging_name, @tagName(std.posix.errno(staging_fd)) });
        return error.ShmOpenFailed;
    }

    const staging_map = try std.posix.mmap(null, staging.regionSize(staging_cap), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, staging_fd, 0);
    defer std.posix.munmap(staging_map);

    const staging_region: []align(staging.cache_line) u8 = staging_map;

    staging.validate(staging_region, staging_cap) catch |err| {
        std.debug.print("RENDERER: staging region invalid: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print("RENDERER: staging region OK via {s} cap={d}\n", .{ staging_name, staging_cap });

    // --- Rasterizer, pack and stream one glyph through the atlas stream ---
    const atlas_region = staging.Staging.init(staging_region, staging_cap);
    var atlas_stream = atlas_region.producer();

    // atlas dims; the host's atlas texture must match
    var packer = atlas.Packer.init(1024, 1024);

    var rast = raster.Rasterizer.init("assets/fonts/DejaVuSans.ttf", 32) catch |err| {
        std.debug.print("RENDERER: rasterizer init failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer rast.deinit();

    var glyph_cov: [256 * 256]u8 = undefined;
    const g = try rast.rasterize('A', &glyph_cov);
    const cell = packer.alloc(g.width, g.height) catch |err| {
        std.debug.print("RENDERER: atlas pack failed: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print("RENDERER: streamed glyph 'A' -> atlas ({d},{d}) {d}x{d}\n", .{ cell.x, cell.y, g.width, g.height });

    const uaddr = try net.UnixAddress.init(sock_path);
    const control = try uaddr.connect(init.io);
    defer control.close(init.io);

    std.debug.print("RENDERER: control channel connected\n", .{});

    // --- Producer ---
    // Build one frame's display list, write a slot, publish
    const frames = frame.Frames.init(region);
    var producer = frames.producer();

    var cmd_buf: [4096]u8 align(8) = undefined;
    var enc = draw.Encoder{ .buf = &cmd_buf };

    const rect = draw.DrawRect{ .x = 32, .y = 48, .w = 240, .h = 120, .rgba = 0x3B82F6FF };

    enc.command(.rect, rect) catch |err| {
        std.debug.print("RENDERER: encode failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // viewport is 0 until the host supplies it via LoadPage/Resize
    producer.writeFrame(.{ .seq = 1, .viewport_w = 0, .viewport_h = 0, .atlas_head_required = atlas_stream.headCursor() }, &.{}, enc.bytes()) catch |err| {
        std.debug.print("RENDERER: writeFrame failed: {s}\n", .{@errorName(err)});
        return err;
    };

    producer.publish();

    std.debug.print("RENDERER: published frame seq=1 ({d} command bytes)\n", .{enc.bytes().len});

    // Publish strictly before signal: FrameReady goes out right after puhblish
    // before we block on input. flags=0 means no wants_tick - this frame is static
    {
        var ctl_buf: [64]u8 = undefined;
        var cw = control.writer(init.io, &ctl_buf);
        const env = protocol.Envelope{ .tag = @intFromEnum(protocol.Tag.frame_ready), .flags = 0, .length = 0, .seq = 1 };

        cw.interface.writeAll(std.mem.asBytes(&env)) catch |err| {
            std.debug.print("RENDERER: FrameReady write failed: {s}\n", .{@errorName(err)});
            return err;
        };

        cw.interface.flush() catch |err| {
            std.debug.print("RENDERER: FrameReady flush failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    std.debug.print("RENDERER: sent FrameReady (after publish)\n", .{});

    // --- Receive control messages until the host closes the channel ---
    std.debug.print("RENDERER: listening for input\n", .{});

    while (true) {
        var env: protocol.Envelope = undefined;

        readExact(control, init.io, std.mem.asBytes(&env)) catch break;

        switch (@as(protocol.Tag, @enumFromInt(env.tag))) {
            .input_event => {
                if (env.length != @sizeOf(protocol.InputEvent)) {
                    std.debug.print("RENDERER: bad InputEvent length {d}\n", .{env.length});
                    drain(control, init.io, env.length) catch break;
                    continue;
                }

                var ev: protocol.InputEvent = undefined;

                readExact(control, init.io, std.mem.asBytes(&ev)) catch break;

                std.debug.print("RENDERER InputEvent kind={d} at ({d},{d}) entity={d} frame_seq={d}\n", .{ ev.kind, ev.x, ev.y, ev.hit_entity, ev.frame_seq });

                // Dispatch into the scene graph lands with the renderer brain
            },
            else => {
                std.debug.print("RENDERER: unexpected tag={d} length={d}\n", .{ env.tag, env.length });
                drain(control, init.io, env.length) catch break;
            },
        }
    }

    std.debug.print("RENDERER: control channel closed, exiting\n", .{});
}
