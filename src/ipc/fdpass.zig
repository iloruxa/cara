//! Pass an open file descriptor across a connected Unix-domain socket via SCM_RIGHTS
//!
//! The host creates the shared-memory regions and hands their fds to the
//! sandboxed renderer through here, so the renderer never opens shared memory by
//! name and a no-open sandbox can still receive its mappings

const std = @import("std");
const builtin = @import("builtin");

// Module imports
const c = std.c;
const posix = std.posix;

// std exposes no public sendmsg/recvmsg (and no CMSG_* helpers), bind libc directly
// recvmsg takes the msghdr mutably: the kernel writes controllen and flags back
extern "c" fn sendmsg(sockfd: posix.fd_t, msg: *const c.msghdr_const, flags: u32) isize;
extern "c" fn recvmsg(sockfd: posix.fd_t, msg: *c.msghdr, flags: u32) isize;

/// The complete ancillary message for exactly one fd: a cmsghdr with the
/// descriptor as its data area. One fd per message keeps the layout a fixed
/// flat struct the compiler can own
const CmsgOneFd = extern struct {
    hdr: c.cmsghdr,
    fd: posix.fd_t,
};

comptime {
    // Only the darwin layout is implemented
    // Linux aligns ancillary data to 8 (CMSG_ALIGN), with a larger cmsghdr and
    // tail padding in controllen, this struct would be silently wrong there so
    // fail loudly instead
    if (!builtin.os.tag.isDarwin()) @compileError("fdpass: darwin-only cmsg layout. Linux needs CMSG_ALIGN(8) handling");

    // The layout IS the wire format: darwin's cmsghdr is 12 bytes and aligns
    // cmsg data to 4, so the fd sits directly after the header and the whole
    // message is 16 bytes no padding
    std.debug.assert(@sizeOf(c.cmsghdr) == 12);
    std.debug.assert(@offsetOf(CmsgOneFd, "fd") == @sizeOf(c.cmsghdr));
    std.debug.assert(@sizeOf(CmsgOneFd) == @sizeOf(c.cmsghdr) + @sizeOf(posix.fd_t));
}

pub const Error = error{ FdSendFailed, FdRecvFailed, NoFdReceived };

/// Send one open fd to the peer over a connected unix socket
pub fn sendFd(sock: posix.fd_t, fd: posix.fd_t) Error!void {
    // One real payload bytes rides along: ancillary data cannot be send on an
    // empty message, and it doubles as framing, the receiver reads exactly one
    // byte per recvFd, so back-to-back sends can never coalesce into one receive
    var byte = [1]u8{0};
    var iov = [1]posix.iovec_const{.{ .base = &byte, .len = 1 }};

    const control = CmsgOneFd{
        .hdr = .{ .len = @sizeOf(CmsgOneFd), .level = c.SOL.SOCKET, .type = c.SCM.RIGHTS },
        .fd = fd,
    };

    const msg = c.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @sizeOf(CmsgOneFd),
        .flags = 0,
    };

    while (true) {
        const n = sendmsg(sock, &msg, 0);

        if (n >= 0) return;
        if (posix.errno(n) != .INTR) return Error.FdSendFailed;
    }
}

/// Receive one fd from the peer. The returned descriptor is a fresh number in
/// this process referring to the same open file the sender passed
/// with CLOEXEC set
pub fn recvFd(sock: posix.fd_t) Error!posix.fd_t {
    var byte: [1]u8 = undefined;
    var iov = [1]posix.iovec{.{ .base = &byte, .len = 1 }};

    var control: CmsgOneFd = undefined;
    var msg = c.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @sizeOf(CmsgOneFd),
        .flags = 0,
    };

    while (true) {
        const n = recvmsg(sock, &msg, 0);

        if (n >= 0) break;
        if (posix.errno(n) != .INTR) return Error.FdRecvFailed;
    }

    // The fd only arrived if a complete, untrucated SCM_RIGHTS message
    // came with it
    if (msg.flags & c.MSG.CTRUNC != 0) return Error.NoFdReceived;
    if (msg.controllen != @sizeOf(CmsgOneFd)) return Error.NoFdReceived;
    if (control.hdr.len != @sizeOf(CmsgOneFd)) return Error.NoFdReceived;
    if (control.hdr.level != c.SOL.SOCKET or control.hdr.type != c.SCM.RIGHTS) return Error.NoFdReceived;

    // nothing received may leak across an exec
    // * Cannot fail on a freshly received descriptor
    _ = c.fcntl(control.fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    return control.fd;
}

// --- Tests ---
const testing = std.testing;

extern "c" fn socketpair(domain: c_uint, sock_type: c_uint, protocol: c_uint, sv: *[2]posix.fd_t) c_int;

test "scm_rights round-trips an fd through a unix socketpair" {
    var sp: [2]posix.fd_t = undefined;
    try testing.expect(socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &sp) == 0);
    defer _ = c.close(sp[0]);
    defer _ = c.close(sp[1]);

    // a pipe whose write end we pass across the socket
    var pf: [2]posix.fd_t = undefined;
    try testing.expect(c.pipe(&pf) == 0);
    defer _ = c.close(pf[0]);
    defer _ = c.close(pf[1]);

    try sendFd(sp[0], pf[1]);
    const got = try recvFd(sp[1]); // a new fd to the same open pipe write end
    defer _ = c.close(got);
    try testing.expect(got != pf[1]);

    // it must carry CLOEXEC, and it must point at the same pipe:
    // write through it, read the byte out of the pipe's read end
    try testing.expect(c.fcntl(got, c.F.GETFD) & c.FD_CLOEXEC != 0);
    try testing.expectEqual(@as(isize, 1), c.write(got, "X", 1));
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try posix.read(pf[0], &buf));
    try testing.expectEqual(@as(u8, 'X'), buf[0]);
}
