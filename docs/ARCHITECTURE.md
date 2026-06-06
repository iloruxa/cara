# Architecture

This document describes how Cara is built. It is the reference for anyone implementing, reviewing, or contributing to the project.

---

## 1. Overview

Cara runs as two operating-system processes communicating through a shared-memory channel and an IPC control channel. The split is the security boundary, the performance boundary, and the conceptual boundary of the system. Every decision below either lives inside one process or describes how the two communicate.

### 1.1 The Stack

```
┌──────────────────────────────────────────────────────┐
│                  RENDERER PROCESS                    │
├──────────────────────────────────────────────────────┤
│  Page Authors' World  —  *.glyph + *.lua             │
├──────────────────────────────────────────────────────┤
│  Standard Component Library                          │
│    box · text · input · button · form · for · …      │
├──────────────────────────────────────────────────────┤
│  Reactivity Layer                                    │
│    signals + DirtyFlags wiring                       │
├──────────────────────────────────────────────────────┤
│  Lua Runtime (LuaJIT, JIT enabled)                   │
├──────────────────────────────────────────────────────┤
│  Scene Graph                                         │
│    entity = u32                                      │
│    hierarchy = first-child / next-sibling indices    │
│    component pools (sparse-set, SoA, flat vectors)   │
│    DirtyFlags drives all incremental work            │
├──────────────────────────────────────────────────────┤
│  Systems                                             │
│    Style · Strict-Box Layout · Paint · Anim · A11y   │
├──────────────────────────────────────────────────────┤
│  Text Trinity                                        │
│    SheenBidi · libunibreak · HarfBuzz · FreeType     │
├──────────────────────────────────────────────────────┤
│  Glyph Parser (zero-allocation, target ~400 LOC)     │
├──────────────────────────────────────────────────────┤
│  Display List Writer  ➤ writes to shared memory      │
└──────────────────────────────────────────────────────┘
                          ║
       ┌──────────────────╨───────────────────┐
       ║  SHARED MEMORY (display list ring)   ║
       ║  + IPC control channel (small msgs)  ║
       └──────────────────╥───────────────────┘
                          ║
┌──────────────────────────────────────────────────────┐
│                    HOST PROCESS                      │
├──────────────────────────────────────────────────────┤
│  Window · OS event pump · Process spawner            │
├──────────────────────────────────────────────────────┤
│  Hit-test (reads ID buffer here)                     │
├──────────────────────────────────────────────────────┤
│  GPU: render backend + color framebuffer + ID buffer │
├──────────────────────────────────────────────────────┤
│  Display List Executor ◀ reads from shared memory    │
├──────────────────────────────────────────────────────┤
│  Net (libcurl + HTTP/2) · Storage (SQLite) ·         │
│  Clipboard · AccessKit platform bridge               │
├──────────────────────────────────────────────────────┤
│  OS / Window                                         │
└──────────────────────────────────────────────────────┘
```

Two boundaries matter: the IPC boundary, which defines the security model, and the shared-memory channel, which defines the performance model. Everything large crosses through shared memory. Everything controlling crosses through IPC. There is no third channel.

### 1.2 The Page Lifecycle

1. **Fetch** — The host negotiates HTTP/2 + TLS 1.3 and retrieves the page bundle.
2. **Renderer spawn and bundle delivery** — The host spawns a renderer process for the origin and delivers the `.glyph` source, `.lua` source, and any assets over IPC.
3. **Glyph parse** — The renderer performs a single-pass, zero-allocation recursive-descent parse. Markdown desugaring runs inline during parsing.
4. **Scene-graph construction** — Entities are spawned, components attached, initial `DirtyFlags` set.
5. **Style resolution** — Each `.utility` token from the parse has already been hash-mapped during the parse phase; no second pass is required.
6. **Lua entry script execution** — The renderer's Lua state runs the page's entry script, which registers signals, bindings, and handler functions.
7. **First frame** — The renderer runs layout (single tree walk), generates a paint pass that writes a display list to shared memory, sends `FrameReady` to the host, and projects the accessibility tree.
8. **Host frame render** — The host acquire-loads the ring head, walks the display list, submits commands to the GPU, presents the frame, and sends `FrameDone`.
9. **Input loop** — Each OS event triggers a host-side ID-buffer pixel read at the event coordinates, an `InputEvent` IPC to the renderer with the hit entity pre-resolved, and a renderer-side dispatch through the entity's parent chain. Signal mutations from handlers set DirtyFlags bits; the renderer schedules incremental work for the next frame.

Steps 1–7 run once per page load. Steps 8–9 are the steady-state loop.

---

## 2. Subsystems

### 2.1 Networking

The host process performs all network I/O. The renderer cannot reach the network directly; this is a sandbox property, not a convenience.

The networking layer uses libcurl with HTTP/2 and TLS 1.3 enabled, RFC-compliant cache, and cookies persisted in the host-side SQLite store. A single `fetch()` capability is exposed to Lua, crossing IPC to the host for execution. Same-origin is the default; cross-origin requests require explicit declaration via a `meta capability=...` node in the Glyph source.

### 2.2 Glyph — The Document Language

Glyph is the markup language pages are written in. A glyph is an inscribed mark — the smallest unit of writing. The language is named for what it produces.

#### 2.2.1 Rationale

HTML carries thirty years of error-correcting state machines, quirks modes, and parser-as-state-machine behavior. Cara does not render HTML, so the parser does not need to inherit any of that. KDL is well-designed but its grammar fights the use cases the document language must serve — its utility-tag syntax isn't actually valid KDL, and its rich-text handling fragments paragraphs into trees. JSON, YAML, and TOML are configuration formats, not document formats; they have no story for mixed content. Markdown alone is excellent for prose but unable to express structured UI. Lua tables would dissolve the declarative/imperative boundary.

Glyph is a purpose-built grammar that takes the parts of each prior art that work and discards the rest.

#### 2.2.2 Grammar

The grammar has four rules:

1. **Nodes** are identifiers. Lowercase identifiers (`box`, `text`, `button`) name built-in primitives. Capitalized identifiers (`Card`, `TodoItem`) name user-defined components imported from Lua.
2. **Utilities** are dot-prefixed tokens (`.flow-col`, `.p-4`, `.bg-blue-500`). At parse time, a compile-time perfect hash maps each utility to a `(component_field, value)` pair, which is OR'd directly onto the entity being constructed.
3. **Attributes** are `key="value"` pairs. Values are quoted strings, bare numbers, or `$identifier` for Lua bindings.
4. **Children** are wrapped in `{ ... }`. Braces are authoritative; indentation is for humans.

Sugar: `#identifier` is shorthand for `id="identifier"`. Content strings (but not attribute values) undergo markdown desugaring at parse time.

#### 2.2.3 Example

```glyph
box #settings-panel .flow-col .p-4 .bg-gray-900 .w-full {
    image src="avatar.png" .w-12 .h-12 .rounded-full

    box .flow-row .gap-2 {
        text .text-xl .bold .text-white "Settings"
        button .bg-blue-500 .rounded .p-2 onClick=$saveData {
            text "Save"
        }
    }
}
```

There is no closing-tag duplication, no string-quoted utility lists, no distinction between semantic and presentational classes. Invalid input produces a parse error with a positional message; there is no quirks mode, no error recovery, and no second chance.

#### 2.2.4 Markdown Desugaring

Strings appearing as a node's content are desugared into a flat sequence of styled spans at parse time. The input:

```glyph
text .text-base "Click **here** to read the [docs](/docs)."
```

produces five sibling entities in the scene graph:

- Span `"Click "` with `.text-base`
- Span `"here"` with `.text-base` and bold
- Span `" to read the "` with `.text-base`
- Link `"docs"` with `href="/docs"` and `.text-base`
- Span `"."` with `.text-base`

By the time the layout system runs, the scene graph contains a flat, cache-friendly array of styled spans. The text pipeline never sees markdown syntax.

The supported markdown is small and deliberate: `**bold**`, `*italic*` / `_italic_`, `~~strikethrough~~`, `` `code` ``, `[link](url)`, and `\` to escape the following character.

Triple-quoted strings (`"""..."""`) opt out of markdown desugaring entirely.

Attribute values are never desugared. The expression `image src="**file.png**"` looks for a file literally named `**file.png**`. The distinction between content positions (which desugar) and attribute positions (which don't) is grammatical, not contextual.

#### 2.2.5 Dynamic Text — The Binding Form

For text content that updates reactively, use `$signal_name` as the entire content:

```glyph
text .text-xl $current_user
```

For mixed static and dynamic content, use sub-spans:

```glyph
text {
    "Welcome back, "
    span .bold $username
    "!"
}
```

The verbosity, relative to HTML's `{username}` interpolation, is intentional. Inline template expressions inevitably grow into Turing-tarpits — conditionals, loops, scoping rules, error semantics, debugging tools. Computation in this system lives in Lua. Documents declare.

#### 2.2.6 The `$` Boundary

The `$` prefix is the only point in Glyph that references Lua. There is no `<script>` tag, no expression syntax, no template directive.

```glyph
button onClick=$saveSettings .bg-blue { text "Save" }
```

At parse time, the renderer records that this entity's `Clickable.handler` is bound to the Lua identifier `saveSettings`. On a click event, the renderer looks up that name in the page's Lua state and invokes it. A missing function logs the click and silently drops it; the page does not crash.

The total Lua-facing surface of the markup language is two characters.

#### 2.2.7 Parser Implementation Requirements

Two implementation contracts are part of the design because they determine whether the parser is correct on day one or subtly wrong six months in.

**Markdown desugaring state lives in a u32 bitmask, not a stack.** The lexer tracks which style modifiers are active using a packed struct:

```zig
const StyleMask = packed struct(u32) {
    bold:          bool,
    italic:        bool,
    strikethrough: bool,
    code:          bool,
    link:          bool,
    _padding:      u27,
};
```

Opening tokens flip the corresponding bit; closing tokens flip it off. Emitting a span copies the current mask onto the span descriptor. This is one instruction per state transition, zero allocations across the entire desugaring pass. The bitmask design does not track nesting order — well-formed markdown is handled correctly, and malformed input closes tokens greedily (any closing token clears its bit regardless of which token opened it). A real stack would cost an allocation that input never should have triggered.

**The parse arena is sized as a function of the source.** The parser uses a single contiguous arena of size `4 × source.len + 16KB`. One allocation at parse start, one free at parse end, zero internal allocations during the parse. The 4× factor accommodates descriptor overhead conservatively; typical documents allocate at roughly 1.5×. Inputs that exceed the arena return `ParseError.OutOfArena` rather than aborting. Callers needing unbounded parse capacity can pass a chained arena allocator; the parser is allocator-agnostic.

#### 2.2.8 Non-Features

Glyph deliberately excludes:

- Indentation-significant syntax. Braces are truth.
- Inline expressions, conditionals, loops, or any other form of computation in the document layer.
- Template inheritance, partials, includes, or any other compositional primitive (user-defined components in Lua handle this).
- Conditional rendering directives (use the `show` component, or signal-driven children).
- CDATA, comments inside attribute values, quirks mode, error recovery.
- Runtime component registration. Component names resolve at parse-tree-to-scene-graph time against the Lua state at that moment.

File extension: `.glyph`. MIME type: `text/glyph`.

### 2.3 Style Resolver

Approximately 220 utilities are compiled into the binary as a perfect hash. Each `.utility` token in Glyph source maps directly to `(component_field, value)` pairs OR'd onto the entity's components during the parse. Variants (`.hover:bg-blue-500`, `.md:flow-row`) produce conditional sub-styles.

For rules the utility vocabulary does not cover (keyframe animations, complex selectors), an optional `styles.glyph` file accepts arbitrary rules with the same syntax as inline utilities.

### 2.4 Scene Graph

```
const Entity = u32;

const HierarchyNode = struct {
    parent:        Entity,
    first_child:   Entity,
    next_sibling:  Entity,
};

const DirtyFlags = packed struct {
    layout:   bool,
    paint:    bool,
    hittest:  bool,
    a11y:     bool,
    style:    bool,
    _padding: u3,
};
```

Hierarchy is stored as first-child / next-sibling indices, giving linear cache-hot tree traversals. Every component pool is `(SparseSet, FlatVector<T>)` — dense storage is one contiguous backing buffer. No boxed nodes, no hash maps of records, no fragmentation.

This invariant — that all component storage is dense and packed — is what makes the architecture's claim of "linear sweep over packed memory" actually true. Every system that reads from these pools relies on it.

### 2.5 Layout — Strict-Box

Layout is **constraints-down, sizes-up**, modeled on Flutter's `RenderBox` algorithm and adapted to the ECS structure.

A parent passes its child a `Constraint { min_w, max_w, min_h, max_h }`. The child returns a single `Size` satisfying the constraint. The parent positions the child and proceeds. There is no constraint solver, no iteration, no convergence. Each entity's `measure()` runs exactly once per layout pass. Total work is O(N).

Two layout modes:

- **Flow** (`.flow-col` / `.flow-row`): children stack sequentially along an axis.
- **Frame** (`.frame`): children stack on top of each other; absolute positioning is supported.

There is no grid mode, no flex-wrap, no automatic tables. Two-dimensional arrangements are produced by nesting flows inside flows. The compromise is intentional — the algorithms required to support grid and flex-wrap correctly are responsible for a meaningful fraction of every existing browser's complexity, and the use cases they serve can be expressed within nested flows at the cost of slightly more verbose markup.

Sizing modifiers: `.w-N` (explicit), `.fill-w` (consume remaining parent space), `.fit-w` (shrink to intrinsic content size). Symmetric for height.

Text measurement during layout invokes the Text Trinity directly. There is no FFI overhead, no callback boundary, and no allocator switching across that interface.

Target implementation size: approximately 2,400 lines.

### 2.6 Paint — Display Lists in Shared Memory

The display list is written into a shared-memory ring buffer mapped read-write into both processes at startup. The IPC control channel carries only a `FrameReady { offset, length }` notification per frame; the bulk of the per-frame data never touches the IPC channel.

**Memory ordering on the ring is non-negotiable.** The producer (renderer) writes draw commands, then performs a Release-store on the head offset. The consumer (host) performs an Acquire-load on the head offset, then reads the commands. Relaxed ordering is incorrect — CPU reordering would permit the consumer to read uninitialized memory. This is the single rule that, if violated, will produce intermittent corruption that is nearly impossible to reproduce.

**No pointers cross the process boundary.** Each `DrawCommand` is a tagged union with a fixed-size header and inline variable-length data. Resources (fonts, images, glyph atlases) are referenced by host-managed integer IDs assigned at upload time. Variable data is referenced by byte offsets relative to the ring buffer base, never by absolute addresses.

Compositing layers are created only when required by `opacity != 1`, non-identity transforms, or explicit z-index lifts. The default is flat paint, which keeps the renderer's working set inside cache.

### 2.7 Text — The Trinity Pipeline

Text rendering is the single hardest subsystem in the project. The pipeline has eight stages:

1. **Bidi resolution** (UAX #9) — SheenBidi
2. **Script itemization** — split into single-script runs
3. **Line break analysis** (UAX #14) — libunibreak
4. **Shaping** — HarfBuzz, per script-run × font
5. **Line layout** — first-fit greedy in v1
6. **Visual reordering** — by Bidi level
7. **Rasterization** — FreeType into a GPU-side glyph atlas
8. **Paint** — textured quads from glyph positions

Selection, caret, and IME are implemented via an `EditState` component on text-bearing entities. Platform IME bridges (TSF on Windows, IMK on macOS, IBus/Fcitx on Linux) are roughly 500 lines of integration code each.

All four text libraries are called as native functions from the layout and paint code, with no intervening abstraction layer. The text pipeline is part of the renderer's translation unit and cache hierarchy.

### 2.8 Hit Testing — In the Host

The host owns the GPU device and therefore owns the ID buffer painted alongside the color framebuffer. The host is also where OS events arrive. So hit-testing belongs in the host.

1. OS event arrives at the host.
2. Host reads one `u32` pixel from the ID buffer at the event coordinates.
3. Host sends `InputEvent { type, x, y, hit_entity, modifiers }` to the renderer.
4. Renderer skips hit-testing entirely and walks the parent chain from `hit_entity` to find the nearest entity carrying the relevant behavior component.

This is O(1) hit-testing with no spatial index, no quadtree, no bounding-box checks. The hit-test is correct under overlap, clipping, masks, and transforms — by construction, because the rasterizer drew the ID buffer using the same geometry it drew the color buffer.

### 2.9 Input

The renderer receives `InputEvent` messages and dispatches capture → target → bubble through the parent chain of the pre-resolved hit entity. Handlers mutate signals; signals OR DirtyFlags bits onto the entities they affect. Focus is tracked via the `Focusable` component pool; keyboard events route to the currently-focused entity.

### 2.10 Scripting Runtime

LuaJIT 2.1 with the JIT compiler enabled. The JIT is safe in this architecture because the renderer process is OS-sandboxed (seccomp on Linux, sandbox_init on macOS, AppContainer on Windows). A JIT escape buys the attacker a process with no filesystem access, no network, and a small typed IPC surface to the host.

Each `lua_State` is constrained:

- Stripped standard library: no `os`, `io`, `debug`, `package`, or raw `load*` functions.
- Custom `require()` that resolves only against the page's bundle.
- Memory limit (default ~32MB) and instruction budget per script invocation.

There is one `lua_State` per page. Tab close destroys the state.

### 2.11 Reactivity

Three primitives:

- `signal(initial) -> Signal` — a read/write cell with a subscriber list.
- `compute(fn) -> Signal` — a derived signal with auto-tracked dependencies.
- `bind(target, signal)` — ties a signal to a node property.

Each `bind()` call records a `DirtyFlags` mask determined statically from the property being bound. The full table:

| Property bound                   | DirtyFlags set on signal change                   |
|----------------------------------|---------------------------------------------------|
| `style.color`, `style.bg`        | `PAINT_DIRTY`                                     |
| `style.opacity`                  | `PAINT_DIRTY`                                     |
| `style.width`, `style.height`    | `LAYOUT_DIRTY` (cascades to ancestors)            |
| `style.padding`, `style.margin`  | `LAYOUT_DIRTY`                                    |
| `text.content`                   | `LAYOUT_DIRTY \| A11Y_DIRTY`                      |
| `children` (For, Show)           | `LAYOUT_DIRTY` on parent, `A11Y_DIRTY` on subtree |
| `clickable.handler`              | (none — handler swap is free)                     |
| `style.hidden`                   | `LAYOUT_DIRTY \| HITTEST_DIRTY`                   |

A per-frame batched scheduler walks the DirtyFlags pool in system order (style → layout → paint → a11y). Each system clears only its own bit. This table is the contract between Lua-driven page logic and the engine's render pipeline.

### 2.12 Standard Component Library

Twenty components, locked vocabulary:

`box`, `text`, `input`, `textarea`, `checkbox`, `select`, `button`, `link`, `image`, `form`, `for`, `show`, `portal`, `scrollable`, `clickable`, `hoverable`, `focusable`.

Lowercase by convention. User-defined components are Capitalized (`Card`, `TodoItem`).

Performance-critical primitives (`box`, `text`, `image`, `scrollable`) live in the engine. Compositional ones (`form`, `for`, `show`, `portal`) live in Lua in the runtime directory.

### 2.13 Accessibility

The accessibility tree is AccessKit-compatible. The renderer projects the scene graph into AccessKit's structure and sends the tree to the host via IPC; the host bridges to platform assistive-technology APIs (UIA on Windows, AX on macOS, AT-SPI on Linux).

Each component contributes its semantic role automatically. Authors do not write ARIA. A `button` is a button. A `link` is a link. The component vocabulary is the semantic vocabulary.

### 2.14 Process Architecture

Two-process topology:

- **Host process**: window, OS event pump, GPU device, networking, storage, clipboard, accessibility bridge, hit-testing. Privileged.
- **Renderer process per origin**: scene graph, Lua, layout, paint command generation, text shaping. Unprivileged — capabilities dropped at startup.

**IPC control channel** (Unix sockets on POSIX, named pipes on Windows) carries small typed messages. The catalog in v1 has twelve message types: `LoadPage`, `Fetch`, `FetchResult`, `StorageOp`, `StorageResult`, `InputEvent`, `FrameReady`, `FrameDone`, `A11yUpdate`, `Resize`, `SpawnRenderer`, `ProcessHealthcheck`.

**Shared memory channel** carries display lists. Mapped read-write into both processes at startup. Never serialized; never copied.

A successful renderer compromise (HarfBuzz exploit, LuaJIT JIT bug, parser bug) yields the attacker a sandboxed process with no syscalls, no filesystem, no network, and a small typed IPC surface. Different origins run in different renderer processes with no shared memory between them.

### 2.15 Storage

A per-origin SQLite key-value store owned by the host. Renderers request reads and writes via IPC. Default quota is 10MB per origin, user-adjustable.

The Lua API is intentionally minimal: `storage.get(key)`, `storage.set(key, value)`, `storage.delete(key)`, `storage.list(prefix)`.

There is no IndexedDB equivalent. If a page needs database-shaped data, it stores SQL-shaped values through this API and structures them on the Lua side.

### 2.16 WASM Tier (Planned, Not Built in v1)

A future capability for applications that need more than the standard component vocabulary:

```glyph
page { app src="myapp.wasm" .w-full .h-full }
```

The host instantiates the WASM module via a runtime such as Wasmtime, hands it a render surface scoped to the node's box, and routes input events into it. The module brings its own UI; Cara provides a render target and capability-restricted I/O.

Not implemented in v1. The architecture is designed such that adding it later is purely additive — no v1 decision precludes it.

---

## 3. The Utility Vocabulary

Approximately 220 utilities, dot-prefixed, compiled into the binary as a perfect hash. The set is locked for v1; adding utilities is easy, but removing them after pages depend on them is impossible.

- **Layout**: `.flow-col`, `.flow-row`, `.frame`, `.hidden`
- **Sizing**: `.w-{0..16}`, `.w-full`, `.w-screen`, `.h-*`, `.max-w-*`, `.min-h-*`, `.fill-w`, `.fill-h`, `.fit-w`, `.fit-h`
- **Alignment**: `.align-{start,center,end,stretch}`, `.justify-{start,center,end,between,around}`, `.gap-{0..16}`
- **Spacing**: `.p-{0..16}`, `.px-*`, `.py-*`, `.pt-*`/`.pb-*`/`.pl-*`/`.pr-*`, same for `.m-*`
- **Typography**: `.text-{xs,sm,base,lg,xl,2xl,3xl,4xl}`, `.bold`, `.italic`, `.underline`, `.strikethrough`, `.font-{sans,serif,mono}`, `.text-{left,center,right}`, `.leading-{tight,normal,loose}`
- **Color** (12-color palette × 9 shades): `.bg-color-N`, `.color-N`, `.border-color-N`
- **Border and shape**: `.border`, `.border-{1,2,4}`, `.rounded-{none,sm,md,lg,xl,full}`
- **Shadow**: `.shadow-{sm,md,lg,xl,none}`
- **Cursor and overflow**: `.cursor-{pointer,text,wait,not-allowed}`, `.overflow-{hidden,scroll,visible}`
- **Position**: `.relative`, `.absolute`, `.top-N`, `.left-N`, `.right-N`, `.bottom-N`

**Variants** (prefix any utility): `.hover:`, `.focus:`, `.active:`, `.sm:`, `.md:`, `.lg:`

---

## 4. Non-Goals

The following are not in scope for v1, and several will never be in scope:

- HTML, CSS, or JavaScript rendering of any kind.
- A DOM shim or any API resembling `document.querySelector`.
- CSS-equivalent features the layout algorithm does not support: `flex-grow` with explicit basis, grid layout, flex-wrap, min-content / max-content distinctions, aspect-ratio without explicit math, floats, columns, tables.
- Browser extensions. Per-page Lua replaces the use cases extensions typically serve.
- Print, PDF generation, or `window.print` equivalents.
- WebRTC, WebSockets, Service Workers, IndexedDB, ContentEditable. HTTP plus Server-Sent Events covers most use cases that motivate these.
- Sync, accounts, cloud features. Cara is a piece of software, not a service.
- DRM, EME, Widevine. Pages requiring these can be served from a browser that implements them.
- Telemetry. Cara makes no network requests on its own behalf.
- A marketplace, theme store, or monetization layer.

---

## 5. Planned Project Layout

```
cara/
├── build.zig
├── ARCHITECTURE.md
├── README.md
├── LICENSE
├── vendor/
│   ├── sheenbidi/             # UAX #9
│   ├── libunibreak/           # UAX #14
│   ├── harfbuzz/              # shaping
│   ├── freetype/              # rasterization
│   ├── libcurl/               # HTTP/2 networking
│   ├── accesskit/             # accessibility bridge
│   ├── sqlite/                # storage + cache
│   ├── wgpu_native/           # render backend
│   ├── luajit/                # scripting
│   └── shmem/                 # cross-platform shared memory
├── src/
│   ├── host/
│   │   ├── main.zig
│   │   ├── window.zig
│   │   ├── event_pump.zig
│   │   ├── hittest.zig
│   │   ├── gpu.zig
│   │   ├── display_list_exec.zig
│   │   ├── net.zig
│   │   ├── storage.zig
│   │   ├── a11y_bridge.zig
│   │   └── spawn.zig
│   ├── renderer/
│   │   ├── main.zig
│   │   ├── glyph/
│   │   │   ├── lexer.zig
│   │   │   ├── parser.zig
│   │   │   ├── markdown.zig
│   │   │   ├── arena.zig
│   │   │   └── spawn.zig
│   │   ├── style/
│   │   ├── scene/
│   │   ├── systems/
│   │   ├── text/
│   │   ├── input/
│   │   ├── lua/
│   │   ├── reactivity/
│   │   ├── components/
│   │   └── a11y/
│   └── ipc/
│       ├── protocol.zig
│       ├── control_channel.zig
│       ├── shmem_ring.zig
│       ├── draw_command.zig
│       ├── host_endpoint.zig
│       └── renderer_endpoint.zig
├── runtime/
│   ├── stdlib.lua
│   ├── reactive.lua
│   ├── components/
│   │   ├── form.lua
│   │   ├── for.lua
│   │   ├── show.lua
│   │   └── portal.lua
│   └── utilities.lua
├── tests/
└── examples/
```

The layout shown is the destination state. The repository at first commit contains only the root-level files.

---

## 6. The Mantra

> One language for structure (Glyph).
> One language for behavior (Lua).
> One vocabulary for style (utilities).
> One layout algorithm (Strict-Box).
> One data structure for everything visible (the scene graph).
> One reactive primitive (signal).
> One render path (scene graph → display list → shared memory → GPU).
> One pool that drives all incremental work (DirtyFlags).
> One sandbox boundary that defines the security model (renderer process).
> One channel for bulk data (shared memory) and one for control (IPC).
> One bitmask for markdown state. One arena per parse.
> No pointers across the boundary.
> No accreted legacy in any layer.
>
> One person should be able to hold this in their head.

If a proposal violates the mantra, the proposal is wrong.
