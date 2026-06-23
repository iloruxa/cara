const std = @import("std");
const atlas = @import("atlas.zig");
const draw = @import("draw");
const frame = @import("frame");
const raster = @import("raster.zig");
const protocol = @import("protocol");
const shaper = @import("shaper.zig");
const staging = @import("staging");
const scene_mod = @import("scene.zig");
const glyph = @import("glyph.zig");
const luau = @import("luau.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");

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

    // TODO: REMOVE THIS
    // --- Luau smoke test (temporary) ---\
    // compile + run a trivial script print result
    {
        const L = luau.cara_luau_open() orelse {
            std.debug.print("RENDERER: luau open failed\n", .{});
            return error.LuauOpen;
        };
        defer luau.cara_luau_close(L);

        const src = "return 1 + 2";

        if (luau.cara_luau_loadstring(L, "smoke", src, src.len) != 0) {
            std.debug.print("RENDERER: luau load erro: {s}\n", .{luau.cara_luau_tostring(L, -1) orelse "?"});
            return error.LuauLoad;
        }

        if (luau.cara_luau_pcall(L, 0, 1) != 0) {
            std.debug.print("RENDERER: luau run error: {s}\n", .{luau.cara_luau_tostring(L, -1) orelse "?"});
        }

        std.debug.print("RENDERER: luau says 1 + 2 = {d}\n", .{luau.cara_luau_tonumber(L, -1)});
    }

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

    // --- Rasterize, pack and stream one glyph through the atlas stream ---
    const atlas_region = staging.Staging.init(staging_region, staging_cap);
    var atlas_stream = atlas_region.producer();

    // atlas dims; the host's atlas texture must match
    var packer = atlas.Packer.init(1024, 1024);

    var rast = raster.Rasterizer.init("assets/fonts/DejaVuSans.ttf", 60) catch |err| {
        std.debug.print("RENDERER: rasterizer init failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer rast.deinit();

    var sh = shaper.Shaper.init(&rast, &packer, &atlas_stream);

    // --- Build the page: parse Glyph -> scene, then style (in parse), layout ---
    const page_src =
        \\box .bg-gray-900 .flow-col .p-4 .gap-2 {
        \\    box .bg-blue-500 .p-4 onClick=$greet {
        \\        text .text-2xl .text-white "Hello Cara"
        \\    }
        \\    box .bg-red-500 .p-4 {
        \\        text .text-white "Welcome to Glyph."
        \\    }
        \\}
    ;

    const scene_ptr = try init.gpa.create(scene_mod.Scene);
    defer init.gpa.destroy(scene_ptr);
    scene_ptr.init();

    var parser = glyph.Parser.init(page_src, scene_ptr);
    const root = parser.parse() catch |err| {
        std.debug.print("RENDERER: parse failed: {s}\n", .{@errorName(err)});
        return err;
    };

    var lay = layout.Layout{
        .scene = scene_ptr,
        .measurer = paint.measurer(&sh),
    };

    // framebuffer-pixel viewport
    // TODO: Host to supply thi via Resize later
    lay.run(root, 2048, 1536);

    const uaddr = try net.UnixAddress.init(sock_path);
    const control = try uaddr.connect(init.io);
    defer control.close(init.io);

    std.debug.print("RENDERER: control channel connected\n", .{});

    // --- Producer ---
    // Build one frame's display list, write a slot, publish
    const frames = frame.Frames.init(region);
    var producer = frames.producer();

    var cmd_buf: [64 * 1024]u8 align(8) = undefined;
    var enc = draw.Encoder{ .buf = &cmd_buf };

    var painter = paint.Painter{
        .scene = scene_ptr,
        .shaper = &sh,
        .enc = &enc,
    };

    painter.paint(root) catch |err| {
        std.debug.print("RENDERER: paint failed: {s}\n", .{@errorName(err)});
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

                const hit: scene_mod.Entity = @bitCast(ev.hit_entity);

                if (ev.hit_entity == 0) {
                    std.debug.print("RENDERER: click ({d},{d}) hit background\n", .{ ev.x, ev.y });
                } else if (scene_ptr.isValid(hit)) {
                    // Bubble: walk parent links from the hit entity to the nearest onClick handler
                    var e = hit;
                    var target = scene_mod.Entity.none;

                    while (true) {
                        if (scene_ptr.on_click[e.index].len > 0) {
                            target = e;
                            break;
                        }

                        const p = scene_ptr.parent[e.index];

                        if (p.isNone()) break;

                        e = p;
                    }

                    if (!target.isNone()) {
                        std.debug.print("RENDERER: click on {s} #{d} -> would call onClick handler '{s}' (entity {d})\n", .{ @tagName(scene_ptr.kind[hit.index]), hit.index, scene_ptr.on_click[target.index], target.index });
                    } else {
                        std.debug.print("RENDERER: click on {s} #{d}, no onClick handler in ancestry\n", .{ @tagName(scene_ptr.kind[hit.index]), hit.index });
                    }
                } else {
                    std.debug.print("RENDERER: click ({d},{d}) hit stale entity 0x{X}\n", .{ ev.x, ev.y, ev.hit_entity });
                }
            },
            else => {
                std.debug.print("RENDERER: unexpected tag={d} length={d}\n", .{ env.tag, env.length });
                drain(control, init.io, env.length) catch break;
            },
        }
    }

    std.debug.print("RENDERER: control channel closed, exiting\n", .{});
}
