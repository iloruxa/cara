# Cara — Architecture Overview

A from-scratch browser built on a **two-process design**: a privileged **host**
and a sandboxed **renderer**, talking over exactly two channels — a
**shared-memory ring** for bulk data and an **IPC control channel** for small
messages.

> High-level map only. Full spec (Glyph grammar, utility vocabulary, layout
> algorithm) lives in [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## The flow, top to bottom

Data flows **down**: the renderer produces a display list; the host consumes it
and paints the screen. Control and input flow back **up** through IPC.

```
  RENDERER PROCESS                         sandboxed · one per origin
  -------------------------------------------------------------------
      Page bundle  (.glyph + .lua)
            |
            v
      Glyph Parser
            |
            v
      Scene Graph (ECS)        <--  driven by Lua (LuaJIT) + Reactivity
            |
            v
      Systems:  Style -> Layout -> Paint -> A11y
            |
            v
      Text Trinity  (SheenBidi, libunibreak, HarfBuzz, FreeType)
            |
            v
      Display List Writer
            |
  ====================  WRITE: Release store on head  ================
            |
            v
      SHARED MEMORY  :  display-list ring buffer   (bulk, per-frame)
      IPC CHANNEL    :  small typed control messages
            |
  ====================  READ: Acquire load on head  =================
            |
            v
      Display List Executor
            |
            v
      GPU  (color framebuffer + ID buffer)
            |
            v
      Window  ->  screen
  -------------------------------------------------------------------
  HOST PROCESS                             privileged · owns the OS
```

The host also owns the OS event pump, hit-testing, the process spawner,
networking, storage, clipboard, and the accessibility bridge — all reachable by
the renderer only through IPC.

---

## Why two processes

| Boundary | What it buys |
|---|---|
| **Security** | A renderer compromise yields a sandboxed process with no filesystem, no network, no syscalls — only the typed IPC surface. Different origins get different renderers with no shared memory between them. |
| **Performance** | Per-frame display lists never cross IPC or get copied; they live in shared memory mapped into both processes. |
| **Conceptual** | Large data goes through shared memory. Control goes through IPC. There is no third channel. |

---

## Renderer process

Sandboxed, unprivileged, one per origin. Turns a page bundle into a display list.

| Component | Role |
|---|---|
| **Glyph Parser** | Single-pass, zero-allocation recursive-descent parse of `.glyph`. |
| **Lua Runtime** | LuaJIT (JIT on, safe behind the OS sandbox). Page behavior. |
| **Reactivity** | `signal` / `compute` / `bind`; mutations set `DirtyFlags`. |
| **Scene Graph** | ECS — entities are `u32`, hierarchy is first-child / next-sibling, components in dense SoA pools. |
| **Systems** | Style -> Strict-Box Layout (constraints down, sizes up) -> Paint -> A11y. |
| **Text Trinity** | SheenBidi (bidi), libunibreak (line break), HarfBuzz (shaping), FreeType (raster). |
| **Display List Writer** | Serializes paint output into the shared-memory ring. |

---

## Host process

Privileged. Owns every OS resource the renderer may not touch.

| Component | Role |
|---|---|
| **Window + Event Pump** | OS window and input events. |
| **Process Spawner** | Launches a renderer per origin. |
| **Display List Executor** | Reads the ring, submits draw commands to the GPU. |
| **GPU** | Render backend, color framebuffer, and a parallel **ID buffer** for hit-testing. |
| **Hit-Test** | Reads one ID-buffer pixel at the event coordinates — O(1), correct under overlap and clipping by construction. |
| **Net** | libcurl, HTTP/2, TLS 1.3. All network I/O lives here. |
| **Storage** | Per-origin SQLite key-value store. |
| **Clipboard** | System clipboard access. |
| **AccessKit Bridge** | Bridges the projected a11y tree to platform APIs. |

---

## The two channels

| Channel | Carries | Ordering rule |
|---|---|---|
| **Shared-memory ring** | Display lists — bulk, one per frame | Producer **Release**-stores `head`; consumer **Acquire**-loads it. Never relaxed. |
| **IPC control channel** | Small typed messages | Sequenced messages over a Unix socket. |

**No pointers cross the boundary.** Draw commands are tagged unions with fixed
headers and inline data; resources are host-assigned integer IDs; variable data
is referenced by byte offset relative to the ring base.

---

## IPC control messages (v1)

| Message | Direction | Purpose |
|---|---|---|
| `SpawnRenderer` | host (internal) | Create a renderer for an origin |
| `LoadPage` | host -> renderer | Deliver the page bundle |
| `Fetch` | renderer -> host | Request a network resource |
| `FetchResult` | host -> renderer | Network response |
| `StorageOp` | renderer -> host | Key-value read / write |
| `StorageResult` | host -> renderer | Storage result |
| `InputEvent` | host -> renderer | Input event, hit entity pre-resolved |
| `FrameReady` | renderer -> host | Display list ready `(offset, length)` |
| `FrameDone` | host -> renderer | Frame presented |
| `A11yUpdate` | renderer -> host | Accessibility tree projection |
| `Resize` | host -> renderer | Viewport changed |
| `ProcessHealthcheck` | host <-> renderer | Liveness |

---

## How a page loads

Steps 1–7 run once per load; 8–9 are the steady-state loop.

1. **Fetch** — host negotiates HTTP/2 + TLS, retrieves the bundle.
2. **Spawn + deliver** — host spawns a renderer, sends the bundle over IPC.
3. **Parse** — renderer parses `.glyph` in one zero-allocation pass.
4. **Build** — scene graph constructed, initial `DirtyFlags` set.
5. **Style** — utility tokens resolved.
6. **Script** — Lua entry script registers signals, bindings, handlers.
7. **First frame** — layout -> paint -> display list -> `FrameReady` -> a11y.
8. **Render** — host Acquire-loads `head`, walks the list, submits to GPU, presents, sends `FrameDone`.
9. **Input loop** — OS event -> host reads ID-buffer pixel -> `InputEvent` -> renderer dispatches -> signal mutations set `DirtyFlags` -> next frame.

---

## The data path, in one line

The single producer to consumer path, synchronized by the Release/Acquire pair
on `head`, is the spine of the system. Every frame travels it:

`Renderer paints -> Display List Writer -> [ring | Release head] -> [Acquire head] -> Display List Executor -> GPU -> screen`

