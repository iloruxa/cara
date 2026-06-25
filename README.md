# Cara

A calmer, kinder web for the **people** who read and write it.

Cara is a small web browser built from scratch. It does not open normal websites, and it never will. Instead it shows its own kind of page, written in a simple format called **Glyph**. By skipping the thirty years of complexity behind today's web (HTML, CSS, JavaScript), Cara stays small enough for one person to understand completely.

Three small pieces, each doing one job:

- **Glyph** is how you write a page. Four simple rules, no legacy quirks: you say what is on the page and how it should look.
- **Luau** is a small, safe scripting language that makes pages interactive, like responding to a click.
- **Zig** is the language Cara itself is written in, top to bottom.

There is no sprawling document model, no JavaScript engine, no tracking, and no app store. This is **a** browser, not *the* browser, and you could read the whole codebase in a weekend.

## How it works

Cara runs as two separate programs that talk to each other:

- The **host** handles everything that touches your computer: the window, the screen, the mouse and keyboard, the network, and saved files.
- The **renderer** handles the page itself: it reads the Glyph file, works out where everything goes, and decides what to draw. Each site gets its own renderer, sealed off from the rest of your machine.

The renderer never draws to the screen directly. It writes down what each frame should look like (a plain list: a box here, some text there), and the host draws it. They share that list through a piece of memory both can read, and send short messages over a private channel. Splitting them apart and sealing the renderer in is the whole point: if a page goes wrong, or turns hostile, it cannot reach the rest of your computer.

- **[`docs/HLD.md`](./docs/HLD.md)**: a five-minute tour.
- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)**: the full design, which wins wherever the two disagree.

## What works today

On macOS, Cara already turns a Glyph page into a real, clickable window:

- It reads a page you write (boxes, colors, text), lays it out, and draws it. None of it is hardcoded.
- Text is drawn with a real font, properly sized and placed.
- Boxes can be nested and stacked in different colors.
- Clicks work. Cara figures out exactly which element you clicked, and finds the code meant to handle it (so clicking the text on a button counts as clicking the button).

## What is not done yet

- **Pages cannot run scripts yet.** A click finds the code that should handle it, but the Luau engine that would actually run that code is not connected. That is the next step.
- No images, no network, no saved data.
- The safety sandbox is designed but not switched on.

## Build and run

Cara runs on **macOS (Apple Silicon)** today; Linux is planned, Windows is not. You need two things on your machine:

- **Zig**, via [anyzig](https://github.com/marler8997/anyzig). It reads the exact version from `build.zig.zon` and runs the matching Zig for you, so there is no version to pick.
- **Xcode Command Line Tools** (`xcode-select --install`), for the macOS frameworks Cara links (Metal, QuartzCore, Cocoa, IOKit).

**1. Clone with submodules.** This also pulls the two vendored libraries, **glfw** (windowing) and **Luau** (scripting); their URLs are recorded in `.gitmodules`, so you do not supply them.

```sh
git clone --recurse-submodules https://codeberg.org/rootkill/cara.git
cd cara
# already cloned without it? run: git submodule update --init --recursive
```

**2. Fetch the GPU library.** Cara draws through **wgpu-native**, a prebuilt static library too large to keep in git, so you fetch it once. From [gfx-rs/wgpu-native releases](https://github.com/gfx-rs/wgpu-native/releases), download the **macOS aarch64** build at version `<WGPU_VERSION>` (the one the vendored `vendor/wgpu.zig` bindings were generated against), then unzip it so the static lib lands at `vendor/wgpu/lib/libwgpu_native.a`:

```sh
mkdir -p vendor/wgpu
unzip wgpu-macos-aarch64-release.zip -d vendor/wgpu
```

(FreeType is fetched automatically the first time you build, and the bundled font is already in the repo, so there is nothing else to download.)

**3. Build and run.**

```sh
zig build run     # build host + renderer, then run (the host spawns the renderer)
zig build         # build only
zig build test    # run the unit tests
```

---

<img alt="Zig Mark" src="./assets/zig-mark.svg" width="400">
