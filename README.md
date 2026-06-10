# Cara

A browser that refuses to render the current web.

The web is what three decades of standards committees and ad-funded browser vendors built when no one was paying attention. HTML, CSS, and JavaScript were not designed for the people writing pages — they were designed to keep the people who own the rendering engines in business. Cara is what happens when you stop accepting that as the only option.

Pages on Cara are written in **Glyph** — a four-rule declarative markup language with no quirks mode, no parser-as-state-machine, and no thirty years of accumulated compatibility tax. Behavior is scripted in **Luau**, interpreter-only — no JIT, and by design no executable memory in the renderer's jail. Layout is constraint-propagated in a single tree walk, and the engine is **Zig**, end to end. There is no DOM, no JavaScript runtime, no telemetry, no marketplace, no extension store, and no opinion about what your homepage should be.

It does not render the existing web, and it never will. This is **a** browser, not *the* browser.

## How it's built

Two processes, two channels — and only two:

- A privileged **host** owns the OS: the window, GPU, network, storage, clipboard, accessibility, hit-testing, and the process spawner.
- A **renderer** (one per origin) owns the page: parsing, scene graph, style, layout, paint, text shaping and rasterization, image decode, and the Luau VM.
- **Shared memory** carries bulk per-frame data — latest-wins frame slots plus an image/atlas staging region; a **Unix socket** carries 13 typed control messages and does the signaling. No pointer ever crosses either boundary.

The renderer produces display-list frames; the host paints the newest and skips the stale. One language for the engine (Zig), one for behavior (Luau), one for documents (Glyph) — small enough that one person can read all of it.

- **[`docs/HLD.md`](./docs/HLD.md)** — the five-minute orientation.
- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)** — the full specification, which governs wherever the two disagree.

## Status

Early, and honest about it. What runs on macOS today is an end-to-end **vertical slice**:

- the host opens a window, creates the shared-memory region, and spawns the renderer, which maps and validates it across the process boundary;
- a Unix-socket control channel, where the renderer's `FrameReady` wakes the host's event loop — no busy-wait;
- a GPU path (wgpu-native, Metal-backed) that clears, presents, draws a rectangle, renders a parallel integer **ID buffer**, and hit-tests in O(1) by reading a single pixel;
- a click resolved in the host and handed to the renderer as a pre-resolved `InputEvent`.

The cross-process transport is still the v1 ring; the latest-wins frame-slot reshape is the next step. Not yet built: the Glyph parser, scene graph, layout, the text pipeline, images, and Luau — the painted frame is a single hardcoded rectangle, and the renderer sandbox is designed but not yet enforced. The architecture spec's §12 has the full as-built picture.

## Build & run

Cara tracks **Zig master** via [`zvm`](https://github.com/tristanisham/zvm) (see `minimum_zig_version` in `build.zig.zon`). The targets are **macOS (Cocoa)** and **Linux (Wayland)** — no Windows; the running slice today is macOS.

```sh
git clone --recurse-submodules <repo-url>
cd cara
zig build run     # build host + renderer, then run the host (it spawns the renderer)
zig build         # build only
zig build test    # run the IPC unit tests
```

## License

MIT — see [`LICENSE`](./LICENSE).
