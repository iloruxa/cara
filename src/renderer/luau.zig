//! Zig view of the Luau C seam (vendor/luau_shim.cpp)
//! This is the entire surface the renderer can touch:
//!     - open a sanboxed state
//!     - compile+load a chunk
//!     - call it
//!     - read results
//!     - close
//!
//! Luau's real headers are never imported here

pub const State = opaque {};

pub extern fn cara_luau_open() ?*State;
pub extern fn cara_luau_close(L: *State) void;
pub extern fn cara_luau_loadstring(L: *State, chunkname: [*:0]const u8, src: [*]const u8, len: usize) c_int;
pub extern fn cara_luau_pcall(L: *State, nargs: c_int, nresults: c_int) c_int;
pub extern fn cara_luau_getglobal(L: *State, name: [*:0]const u8) c_int;
pub extern fn cara_luau_type(L: *State, idx: c_int) c_int;
pub extern fn cara_luau_tonumber(L: *State, idx: c_int) f64;
pub extern fn cara_luau_tostring(L: *State, idx: c_int) ?[*:0]const u8;
pub extern fn cara_luau_pop(L: *State, n: c_int) void;
