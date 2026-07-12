//! Seatbelt lockdown
//!
//! the renderer holds every resource it will ever own before this call (shm fds
//! received over SCM_RIGHTS, the control socket, the font), so the profile can
//! be the strictest one Seatbelt accepts: DENY everything
//!
//! Under deny defaults, oprations on already-held resources keep working:
//! malloc, read/write on open fds, existing mappings, and new mmaps of a held
//! fd, which Resize remapping requires. Acquiring anything new is denied: open
//! shm_open, and PROT_EXEC mappings required

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Linux gets seccomp-BPF, a separate mechanism (not this file)
    if (!builtin.os.tag.isDarwin()) @compileError("sandbox.zig: Seatbelt is darwin-only. Linux uses seccomp-BPF");
}

extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn sandbox_free_error(errorbuf: [*:0]u8) void;

const profile = "(version 1)(deny default)";

pub const Error = error{SandboxInitFailed};

/// Point of NO-RETURN: after this the process can only compute and use what it
/// already holds. Call after the last resource acquisition and before the first
/// byte of untrusted content
pub fn lockdown() Error!void {
    var errbuf: ?[*:0]u8 = null;

    if (sandbox_init(profile, 0, &errbuf) != 0) {
        if (errbuf) |e| {
            std.debug.print("RENDERER: sandbox_init: {s}\n", .{e});
            sandbox_free_error(e);
        }

        return Error.SandboxInitFailed;
    }
}
