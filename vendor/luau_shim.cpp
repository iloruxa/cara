// The C seam over Luau's C++ API.
// Luau's own headers are C++ with no extern "C"
// so their symbols are name-mangled; we never bind them directly
// This shim calls them as C++ and re-exports exactly what the
// renderer needs with a C linkage
// Interpreter-only: we never touch Luau.CodeGen, and it is never compiled in

#include "lua.h"
#include "luacode.h"
#include "lualib.h"
#include <stdlib.h>

extern "C" {
// Fresh state + standard libs, then locked into the sandbox
lua_State *cara_luau_open(void) {
  lua_State *L = luaL_newstate();
  if (!L)
    return nullptr;
  luaL_openlibs(L);
  // NOTE: luaL_sandbox is deferred for now
  // Can be done when implementing per-page sanboxed threads
  // luaL_sandbox(L);
  return L;
}

void cara_luau_close(lua_State *L) { lua_close(L); }

// Compile source to bytecode and load it as a chunk (function left on the
// stack) Returns 0 on success; nonzero leaves an error message on the stack
int cara_luau_loadstring(lua_State *L, const char *chunkname, const char *src,
                         size_t len) {
  size_t bclen = 0;
  // options=NULL -> defaults
  char *bc = luau_compile(src, len, nullptr, &bclen);
  int rc = luau_load(L, chunkname, bc, bclen, 0);
  free(bc);
  return rc;
}

int cara_luau_pcall(lua_State *L, int nargs, int nresults) {
  return lua_pcall(L, nargs, nresults, 0);
}

int cara_luau_getglobal(lua_State *L, const char *name) {
  return lua_getfield(L, LUA_GLOBALSINDEX, name);
}

int cara_luau_type(lua_State *L, int idx) { return lua_type(L, idx); }

double cara_luau_tonumber(lua_State *L, int idx) {
  return lua_tonumber(L, idx);
}

const char *cara_luau_tostring(lua_State *L, int idx) {
  return lua_tostring(L, idx);
}

void cara_luau_pop(lua_State *L, int n) { lua_settop(L, -(n)-1); }

int cara_luau_isfunction(lua_State *L, int idx) {
  return lua_isfunction(L, idx);
}
}
