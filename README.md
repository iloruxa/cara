# Cara

A calmer, kinder web for the **people** who read and write it.

Cara is a small, from-scratch browser. It does not render the existing web, and it never will. It renders Glyph, its own document format, and so carries none of the thirty years of compatibility complexity in HTML, CSS, and JavaScript.

**Glyph** is a tiny four-rule markup language with no quirks mode and none of the accumulated compatibility tax. Behavior is scripted in **Luau**, interpreter-only, with no executable memory in the renderer's sandbox. Layout is a single pass of constraint propagation, and the engine is **Zig**, end to end. There is no DOM, no JavaScript runtime, no telemetry, no marketplace, and no opinion about what your homepage should be.

This is **a** browser, not *the* browser. The whole engine is meant to fit in one person's head, and you can read all of it in a weekend.

## How it's built

Two processes, two channels, and only two:

- A privileged **host** owns the OS: the window, GPU, network, storage, clipboard, accessibility, hit-testing, and the process spawner.
- A **renderer** (one per origin) owns the page: parsing, scene graph, style, layout, paint, text shaping and rasterization, image decode, and the Luau VM.
- **Shared memory** carries bulk per-frame data (latest-wins frame slots plus an image/atlas staging region); a **Unix socket** carries 13 typed control messages and does the signaling. No pointer ever crosses either boundary.

The renderer produces display-list frames; the host paints the newest and skips the stale. One language for the engine (Zig), one for behavior (Luau), one for documents (Glyph), small enough that one person can read all of it.

- **[`docs/HLD.md`](./docs/HLD.md)**: the five-minute orientation.
- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)**: the full specification, which governs wherever the two disagree.

## Status

Early, and honest about it. What runs on macOS today is an end-to-end **vertical slice**:

- the host opens a window, creates the shared-memory region, and spawns the renderer, which maps and validates it across the process boundary;
- a Unix-socket control channel, where the renderer's `FrameReady` wakes the host's event loop (no busy-wait);
- a GPU path (wgpu-native, Metal-backed) that clears, presents, draws a rectangle, renders a parallel integer **ID buffer**, and hit-tests in O(1) by reading a single pixel;
- a click resolved in the host and handed to the renderer as a pre-resolved `InputEvent`.

The cross-process transport is still the bring-up ring; the latest-wins frame-slot reshape is the next step. Not yet built: the Glyph parser, scene graph, layout, the text pipeline, images, and Luau; the painted frame is a single hardcoded rectangle, and the renderer sandbox is designed but not yet enforced. The architecture spec's §12 has the full as-built picture.

## Build & run

Cara tracks **Zig master**; the exact version is pinned by `minimum_zig_version` in `build.zig.zon`, and [anyzig](https://github.com/marler8997/anyzig) reads that field to run the matching Zig per project. The targets are **macOS (Cocoa)** and **Linux (Wayland)**, no Windows; the running slice today is macOS.

```sh
git clone --recurse-submodules <repo-url>
cd cara
zig build run     # build host + renderer, then run the host (it spawns the renderer)
zig build         # build only
zig build test    # run the IPC unit tests
```

# 

![zig](./assets/zig-mark.svg)
