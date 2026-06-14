# Cara: Architecture

This document describes how Cara is built. It is the single reference for anyone implementing, reviewing, or contributing to the engine. It describes the system as designed, not a history of how the design arrived here.

Cara is a from-scratch web browser written in **Zig**. No engine fork. No WebView. It renders **Glyph** (a purpose-built markup language, `.glyph`), scripted with **Luau**, laid out by strict constraint propagation, and painted through a component scene graph that owes more to a game engine than to a document tree.

# 

## 1. North Star

A new browser. Not *the* browser. **A** browser.

It does not render the existing web, and it never will. It therefore carries none of the thirty years of compatibility complexity accumulated by HTML, CSS, and JavaScript.

One person should be able to read the entire source. One person should be able to fork it on a weekend. The whole engine should fit in the working memory of one motivated human.

Two constraints rank above all others, and every decision below is answerable to them:

- **Minimal.** Anything more complex than strictly necessary gets cut. Defend every line against the question: *do we genuinely need this?*
- **Quiet.** Idle costs nothing, and every byte of resident memory is accounted for. A browser nobody is looking at should be indistinguishable from a browser that is not running.

**Minimal means minimal *first-party* code and architecture, not minimal dependencies.** Correct Unicode, shaping, rasterization, TLS, and storage are not weekend projects, and Cara vendors that irreducible surface (HarfBuzz, FreeType, SheenBidi, libunibreak, libcurl, SQLite, AccessKit, Luau, glfw) deliberately, each behind a seam. What we author is the engine; what we bind are the domains where reimplementation would be vanity.

"Simpler" and "cheaper" here are active engineering choices, earned line by line, not automatic properties of doing less.

# 

## 2. The Stack

Two processes. Data flows down: the renderer produces frames, the host paints them. Control flows back up over IPC.

```
  RENDERER PROCESS                 100% Zig · sandboxed · one per origin
  ----------------------------------------------------------------------
      Page bundle  (.glyph + .luau)
            |
            v
      Glyph Parser            zero-alloc recursive descent, markdown desugar
            |
            v
      Scene Graph (ECS)       <-- Luau (interpreter) + Reactivity drive this
            |
            v
      Systems                 Style -> Strict-Box Layout -> Paint -> A11y
            |
            v
      Text Trinity            SheenBidi · libunibreak · HarfBuzz · FreeType
      + Glyph Atlas           shaping + rasterization + atlas layout, here
            |
            v
      Frame Producer          display list + damage -> slot; glyphs -> stream
            |
  ==========|=====  publish: atomic exchange on `latest` (acq_rel)  =====
            v
      SHARED MEMORY           3 frame slots (latest-wins) + staging (images · atlas stream)
      IPC CHANNEL             Unix socket: 13 typed control messages
            |
  ==========|=====  consume: atomic exchange on `latest` (acq_rel)  =====
            v
      Frame Executor          walk the newest frame only; skip stale ones
            |
            v
      GPU (gpu.zig seam ⚑)    color framebuffer + ID buffer + atlas mirror
            |
            v
      Window -> screen        present on vsync; FrameTick back to renderer
  ----------------------------------------------------------------------
  HOST PROCESS                100% Zig · privileged · owns the OS
```

The host owns everything privileged: the window and OS event pump, the GPU device, networking, storage, the clipboard, the accessibility bridge, hit-testing, and the process spawner. The renderer reaches any of it only through IPC.

**Two boundaries, and only two.** The IPC boundary exists for *security*. The shared-memory channel exists for *performance*. Everything large crosses through shared memory. Everything controlling crosses through IPC. There is no third channel.

# 

## 3. The Two Channels

### 3.1 Frame Slots: a latest-wins triple buffer

Frames are replace-semantics, not stream-semantics. If the renderer produced two frames while the host was busy, the host must paint only the newest and discard the stale one. A ring buffer would force it to walk both; a triple buffer lets it skip.

The shared region is one header page plus three fixed frame slots:

```
  offset       contents
  ---------    ------------------------------------------------------
  0x0000       Identity: magic 'CARA' | version  (renderer-checked*)
  cache line   `latest`: packed (slot | dirty | generation), own line
  0x1000       Slot 0   } each slot: FrameHeader + 8-aligned commands
  0x1000 + S   Slot 1   } S = slot_size (starts 256 KiB; the geometry is
  0x1000 + 2S  Slot 2   } self-describing in the header)
```

\* "Renderer-checked" is a *compatibility* property, not a trust property: the host writes the magic|version stamp once at creation, the renderer sanity-checks it on map (binary-skew guard), and the host never reads it (or any layout-defining value) back from this memory. Slot geometry (size, count, offsets) is comptime constants in the shared `frame.zig` module both binaries build from, so no geometry crosses shared memory at all (§5.17).

**The protocol (single-producer, single-consumer):**

- The **producer** writes a complete frame into its private back slot, then performs one **atomic exchange** on `latest`, swapping in `(back_slot | dirty=1 | gen +% 1)`. The value handed back becomes its next back slot. The producer publishes *and then* sends `FrameReady`, never the reverse; a signal that races ahead of its publish is a lost frame.
- The **consumer first acquire-loads** `latest` and proceeds only if `dirty=1`. Then it performs one **atomic exchange**, swapping in its current front slot with `dirty=0`; the value received is the newest complete frame and becomes its new front. **The check before the exchange is load-bearing:** in a latest-wins world signals coalesce, so spurious `FrameReady` wakeups are normal; an unconditional exchange on one would trade the consumer's only valid frame for a stale slot. The consumer holds its front slot until the moment it takes a newer one, because window expose and resize need the last frame re-encodable. That one held slot is the only state the host carries: "stateless" means no retained *list* and no patching, not amnesia.

Both exchanges are **acquire-release**. The producer's release half publishes every frame byte written before it; the consumer's acquire half makes those bytes visible. Relaxed ordering here is a data race that corrupts under load. This is not negotiable.

(The `generation` bits are not required for latest-wins correctness: the dirty bit alone carries that. They exist so the word is guaranteed to change on every publish, which the future Linux futex-wait on `latest` needs even under pathological slot-reuse patterns, and they make frame tracing free. Two bits of "more than minimal," bought for a named reason.)

**What this buys us, structurally:** there is no wraparound, no end-of-buffer sentinel, no free-space arithmetic, no full/empty ambiguity, and no producer backpressure. The producer never blocks. The consumer never reads a torn or stale frame: a slot is either fully written and then published by the exchange, or it is not visible at all. Tearing is impossible by construction.

**Frame contents.** A `FrameHeader { seq, viewport_w, viewport_h,
atlas_head_required, damage_rect_count, command_bytes }`, followed by the damage rectangles and the display list. `viewport_w/h` let the host detect a stale-size frame mid-resize and scale-blit the old content instead of glitching; `atlas_head_required` names the atlas-stream position (§3.3) this frame's text runs depend on. Glyph bitmaps do **not** ride inside frames; §3.3 explains why they cannot. Every draw command's size is rounded up to 8 bytes and `slot_size % 8 == 0` is asserted at comptime, so the consumer `@ptrCast`s commands in place with zero copies, *after* validating each field against host-owned bounds and reading it exactly once, never trusting the attacker-controlled bytes it casts over (§5.17). Zero-copy is a performance property; it is not an extension of trust.

**Display lists are full per produced frame.** Sending the whole list every time keeps the host completely stateless: no host-side retained list, no patch protocol to version. Honest sizing: per-glyph commands would put a text-dense page in the *hundreds* of kilobytes (≈32 B × thousands of visible glyphs), so glyphs travel as **run commands** (one `DrawTextRun` carries a base position, shared style, an atlas reference, and a packed array of glyph ids + advances) which brings a full screen of text back to a few tens of kilobytes. Damage rectangles serve twice: the host **culls leaf draw commands against them on the CPU** while encoding (state commands, `Clip` push/pop, are never culled, or everything after them corrupts; the GPU scissor rejects fragments, not primitives: culling skips the vertex work too), and the render pass is scissored to them. One precondition damage cannot skip: it assumes the acquired backbuffer already holds the *previous* frame's pixels, which is true only at swapchain buffer age 1; and Vulkan acquisitions are formally undefined-content unless the host tracks ages itself. When the age is ≠ 1 or unknown, the host re-encodes the **full held slot** (always possible, because full-list-per-frame plus the held front slot make every frame fully reconstructible) and applies damage only when the age says it may. The incremental work of deciding what changed lives renderer-side, in DirtyFlags, never in host-side list patching.

**No pointers cross the boundary, ever.** Resources are renderer-assigned integer IDs (atlas slots, texture handles). Variable data is referenced by byte offset relative to the slot base. Both shared regions are trivially relocatable in either address space.

**Crash-graceful from the first commit.** Shared-memory names are PID-namespaced. Startup performs a defensive pre-`shm_unlink` to self-heal a stale name left by a prior hard crash. Teardown is `defer`-based. `defer` cannot run on `SIGKILL` or a segfault, but the kernel reclaims the mapping and the next run's pre-unlink recovers the name.

### 3.2 IPC Control Channel

A Unix socket carrying small, typed, length-prefixed messages (`tag u16 · flags u16 · length u32 · seq u32 · payload`). Thirteen message types:

| Message | Direction | Purpose |
|---|---|---|
| `SpawnRenderer` | host internal | bring up a renderer for an origin |
| `LoadPage` | host → renderer | deliver the page bundle |
| `Fetch` | renderer → host | request a network resource |
| `FetchResult` | host → renderer | response bytes (incl. raw image bytes) |
| `StorageOp` | renderer → host | KV get / set / delete / list |
| `StorageResult` | host → renderer | storage result |
| `InputEvent` | host → renderer | input; hit entity pre-resolved against the last *presented* frame, whose `seq` rides along |
| `FrameReady` | renderer → host | a new frame slot was published; carries `wants_tick` |
| `FrameTick` | host → renderer | vsync, **only while armed by `wants_tick`**; paces animation |
| `UploadDone` | host → renderer | image staging consumed, reusable |
| `A11yUpdate` | renderer → host | accessibility tree projection |
| `Resize` | host → renderer | viewport + the staging region’s new size (sent after the grow) |
| `ProcessHealthcheck` | host ↔ renderer | liveness |

The socket is also the **signaling layer**. The host blocks on it (`kqueue` on macOS, `epoll` on Linux) inside a per-renderer IPC thread, and wakes the GUI thread with `glfwPostEmptyEvent()`. Shared memory is transport and is never used for signaling. A Unix socket is portable across both targets, unlike a futex or `eventfd` (Linux-only) or POSIX unnamed semaphores (absent on macOS). A futex on `latest` is a possible Linux-only optimization later; at one signal per frame it is unnecessary.

### 3.3 Staging Region: images, and the one true stream

A second shared region per renderer, created lazily **by the host** and handed to the sandboxed renderer as a file descriptor over the socket (`SCM_RIGHTS`); the renderer can open nothing itself. It carries the two payloads that do not belong in frame slots.

**Decoded images are idempotent.** The renderer decodes (the decoder, a classic attack surface, stays jailed), writes the pixels once, and *every* `DrawImage` referencing the resource repeats the same `(resource_id, offset, size)` until the host's `UploadDone` arrives. A skipped frame therefore skips nothing: the next frame repeats the reference, the host uploads on first sight, and the staging space recycles on the ack. A resource the host never sighted (frame skipped, image scrolled away) is reclaimed by the renderer alone; no upload ever happened, so no ack is owed. No image decode ever runs inside the privileged process.

**Glyph-atlas additions are not idempotent: they are the system's one true stream.** A new glyph's bitmap must reach the host's atlas texture *exactly once, in order, never skipped*; and latest-wins frame consumption is allowed to skip frames. Those two facts together forbid carrying atlas bitmaps inside frames: skip the frame, lose the bitmap, and every later `DrawTextRun` referencing that atlas slot samples uninitialized texture memory. So the staging region contains an **atlas stream**: an append-only run of `(slot rect, bitmap bytes)` entries governed by a monotonic cursor pair: `atlas_head` (renderer, Release-advanced after writing) and `atlas_tail` (host, Release-advanced after uploading), each Acquire-loaded by the other side, `used = head -% tail`, never order-compared. Each `FrameHeader` declares `atlas_head_required`: the **floor** the host must have drained before drawing that frame. In practice the host drains to `atlas_head`, everything available, whenever it consumes a frame: uploading a glyph early is harmless, and it frees stream space a frame sooner.

**Capacity invariant: pin this or the stream deadlocks.** The only thing that advances `atlas_tail` is the host consuming a frame, and a frame cannot be published until its bitmaps are in the stream. If a single frame's additions exceeded capacity, the renderer would block mid-paint with *nothing yet published*; the host would never drain, the tail would never move, and the "wait" would be a hang, most plausibly on the very first, glyph-dense frame (a CJK-heavy first screen is the canonical victim). So the stream must always hold **at least one frame's worst-case additions**: bounded by the viewport's texel count in coverage bytes plus entry headers (a frame cannot
newly reference more glyph coverage than it has pixels to display) which is single-digit megabytes even at 4K, the *bound*; the allocation, at 2× slack, lands near sixteen. The host sizes the region from the viewport at creation and grows it on `Resize` under the handshake below; it owns both. With the invariant pinned, liveness is a two-case argument: before the first publish the renderer never blocks, because one frame's additions always
fit; after the first publish, a published frame always exists whenever the renderer blocks, so the host's next consumption drains to head, advances the tail, and releases it. That residual wait (several glyph-dense frames in flight while the host lags) is the only backpressure anywhere in the system, bounded and rare.

**Growing the stream on `Resize`: the handshake is load-bearing.** The
capacity invariant is viewport-derived, so the grow must happen-before the message that licenses larger production. The order is fixed: (1) the host `ftruncate`s the staging object up *before* sending `Resize`: send first and the renderer's first larger-viewport frame races the capacity guarantee against the old size; (2) the renderer, on receiving `Resize` (which carries the viewport **and the staging region's new size**, geometry traveling the trusted host→renderer direction) remaps at that size *before* any layout or
rasterization for the new viewport; it **keeps the staging fd it was handed at creation** precisely so this is one `mmap` call, which the sandbox already allows; the jailed renderer can open nothing, so without the retained fd this step is impossible; (3) in-flight stream entries survive the grow (`ftruncate` upward preserves bytes and every offset is relative to the region base) stated here so nobody "defends" against it. The region is **grow-only**: a smaller viewport simply uses less of it, which buys back a shrink-truncation hazard for the price of a few idle megabytes.

Different semantics, different transport: **frames are latest-wins; atlas additions are a stream.** The monotonic Release/Acquire cursor pair proven in this project's foundation was deleted from the frame path because frames are not a stream; and it returns here, verbatim, for the one flow that is.

# 

## 4. The Page Lifecycle

Steps 1–6 run once per load. Steps 7–8 run only when something changes.

1. **Fetch** (host). libcurl negotiates HTTP/2 + TLS 1.3 and retrieves the bundle.
2. **Spawn the renderer** and IPC the page bundle (`.glyph` + `.luau` + assets) to it.
3. **Parse Glyph** (renderer): zero-allocation recursive descent, markdown desugaring inline.
4. **Construct the scene graph**: entities, components, initial DirtyFlags. Styles resolve here: `.utility` tokens were already hash-mapped during the parse.
5. **Compile and run the Luau entry script**, inside the renderer, from source. Bytecode never crosses the trust boundary. Signals, bindings, and handlers register.
6. **First frame** (renderer): Strict-Box layout (one tree walk, constraints down, sizes up); newly rasterized glyphs append to the atlas stream (§3.3); paint emits the display list and damage rects into a free slot; the `latest` exchange publishes it, and only then do `FrameReady` and the A11y projection go over IPC.
7. **Host renders**: it wakes on `FrameReady`, checks `dirty` and exchange-takes the newest slot, drains the atlas stream to its head (with `atlas_head_required` as the floor), walks the display list once, runs a single render pass writing the color framebuffer and the ID buffer, and presents. While the last frame's `wants_tick` flag is set, it sends `FrameTick` on vsync; a clean page is never ticked.
8. **Steady state: strictly event-driven.**
   - *Input:* an OS event reaches the host; the host reads one ID-buffer pixel and sends `InputEvent { hit_entity, frame_seq, … }`; the renderer dispatches capture/bubble; handlers mutate signals; DirtyFlags bits get set; the next frame is produced.
   - *Animation:* the renderer steps timelines only on `FrameTick`, armed by `wants_tick` on `FrameReady` and disarmed the moment no timeline is live.
   - *Otherwise:* nothing is dirty, so nothing is produced, nothing is submitted, and nobody wakes. Idle CPU is 0%. Idle GPU is 0%.

# 

## 5. Subsystems

### 5.1 Networking (host)

libcurl with HTTP/2 and TLS 1.3, vendored and bound at the FFI seam.
RFC-compliant cache and cookies persisted in SQLite. A single `fetch()` capability is exposed to Luau and crosses IPC to the host for execution. Same-origin by default; cross-origin requires an explicit `meta capability=...` in Glyph. Every socket lives in the host; the renderer cannot open one.

That last sentence is the renderer's most important denial, and `Fetch` hands the capability back; so the policy is **enforced host-side**, never trusted to the renderer. The origin a request is checked against is the one the host assigned at spawn, not an origin the renderer names; the same-origin rule and any `capability` grant are evaluated by the host against the page's manifest, a compromised renderer cannot widen them. Destinations are filtered before connect: `http`/`https` schemes only, and loopback, link-local (169.254/fe80), private ranges (10/172.16/192.168), and cloud-metadata addresses (169.254.169.254) are refused. The filter re-runs after **every redirect**: a public URL that 302-redirects to the metadata endpoint must not slip through a front-door check. And the filter operates on the **resolved address the connector will actually dial**, never the hostname; the classic bypass that redirect-rechecking alone misses is **DNS rebinding**: a hostname that resolves to a public IP at check time and to a private or metadata IP at connect time, courtesy of a low TTL. So the sequence is resolve once, validate **every** returned address after normalization (IPv4-mapped IPv6 like `::ffff:169.254.169.254` and exotic encodings collapse to the real range before the check), then **pin the validated IP for the connection** (libcurl's the check), then **pin the validated IP for the connection** (libcurl's hostname is a claim; the dialed IP is the fact. Without this, denying the renderer `socket` buys nothing: the
compromise reaches the cloud metadata service, internal services on loopback, and the private network through the host's own connection.

### 5.2 Glyph: the Cara document language

A four-rule markup language for declarative UI on a constraint-propagation engine. The parser is specified at roughly 400 lines of Zig recursive descent, a target, not yet code (see §12), and performs zero internal allocations during a parse.

**Why not anything that already exists.** HTML carries thirty years of error-correcting state machines and quirks modes; we do not render the web, so we need no HTML parser. KDL is a fine config format and a poor document format: its utility-tag syntax is not valid KDL, and its rich-text story fragments paragraphs into trees. JSON, YAML, and TOML are not document languages and have no story for mixed content. Markdown alone is wonderful for prose and useless for structured UI. Lua tables would work and would dissolve the declarative/imperative firewall that keeps the engine fast and safe.

#### The grammar: four rules

1. **Nodes** are identifiers. Lowercase (`box`, `text`, `button`) are built-in primitives; Capitalized (`Card`, `TodoItem`) are user-defined components imported from Luau.
2. **Utilities** are dot-prefixed tokens (`.flow-col`, `.p-4`, `.bg-blue-500`) that map at parse time, through a compile-time perfect hash, to `(component_field, value)` pairs OR'd into the entity's components.
3. **Attributes** are `key="value"` pairs: quoted strings, bare numbers, or `$identifier` for a Luau binding.
4. **Children** live inside `{ ... }`. Braces are authoritative; indentation is for humans.

Sugar: `#identifier` is shorthand for `id="identifier"`. Strings that appear as a node's content (never as attribute values) are markdown-desugared.

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

Invalid input is a parse error with a position. There is no quirks mode and no error recovery.

#### Rich text via markdown desugaring

A content string desugars into a flat sequence of styled span entities at parse time. `"Click **here** to read the [docs](/docs)."` becomes five sibling entities under the parent: plain, bold, plain, link, plain. By the time layout
runs, the scene graph holds a flat, cache-friendly array of styled spans; the Text Trinity never sees markdown.

Supported, deliberately small: `**bold**`, `*italic*` / `_italic_`, `~~strikethrough~~`, `` `code` ``, `[link](url)`, and `\` to escape the next character. Triple-quoted strings (`"""..."""`) opt out of desugaring entirely. Attribute values are never desugared: `image src="**file.png**"` looks for a file literally named `**file.png**`. The distinction is grammatical: content positions desugar, attribute positions do not.

Two implementation details are part of the design, because they decide whether the parser is correct on day one or subtly wrong in month six:

- **Markdown state is a register-resident `u32` bitmask**, not a stack. The active modifiers are a `packed struct(u32)` with `bold`, `italic`, `strikethrough`, `code`, and `link` bits. Opening a token sets its bit; closing clears it; emitting a span copies the mask onto the span descriptor. Zero allocation, one instruction per state change. The trade-off is that nesting order is not tracked: well-formed input is exact, and malformed input closes greedily and degrades predictably. A real stack would cost an allocation we will not pay for input that should not exist.
- **The arena is sized to the source.** A single contiguous arena of `4 × source.len + 16 KiB`, served by a `FixedBufferAllocator`: one alloc, one free, zero internal allocations during the parse. The 4× factor covers descriptor overhead; typical documents land near 1.5×. On overflow the parser returns `ParseError.OutOfArena` rather than aborting; a caller expecting unbounded input passes an `ArenaAllocator` instead. The parser is allocator-agnostic.

#### Dynamic text and the `$` boundary

`$signal_name` as a node's entire content binds it reactively; mixed static and dynamic content uses sub-spans. The `$` prefix is the *only* place Glyph references Luau: there is no script tag, no expression syntax, and no template directive. At parse time the binding records the Luau identifier; on the event, the renderer resolves it in the page's VM. A missing function is logged and dropped, and the page does not crash. Two characters of surface area. That is the entire contract.

#### What Glyph does not have

Indentation significance. Inline expressions or computation. Template inheritance, partials, or includes. Conditional rendering directives (use the `show` component or signal-driven children). CDATA, attribute-value comments, quirks mode, or error recovery. Runtime-registered custom elements: component names resolve against the loaded Luau state at scene-construction time.

File extension `.glyph`. MIME type `text/glyph`.

### 5.3 Style resolver

The ~220-utility vocabulary is compiled into the binary as a perfect hash. Each `.utility` token resolves to a `(component_field, value)` pair during the parse. Variants (`.hover:bg-blue-500`, `.md:flow-row`) produce conditional sub-styles. An optional `styles.glyph` file is the escape hatch for the small fraction of cases the vocabulary does not reach.

### 5.4 Scene graph

```zig
const Entity = u32;

const HierarchyNode = struct {
    parent:       Entity,
    first_child:  Entity,
    next_sibling: Entity,
};

const DirtyFlags = packed struct {
    layout:  bool,
    paint:   bool,
    hittest: bool,
    a11y:    bool,
    style:   bool,
    _pad:    u3,
};
```

Roughly twenty component pools, each a `(SparseSet, FlatVector<T>)` whose dense storage is one contiguous `[]T`. The hierarchy is first-child / next-sibling indices, giving linear, cache-hot tree traversals. No boxed nodes, no hash maps of records, no fragmentation. Entity recycling is generation-guarded: the `Entity` word itself packs `(index | generation)`, and every pool access validates the generation, so a stale handle fails closed instead of aliasing
whatever now occupies the slot. **Indices are u32, never pointers**: half the footprint of a pointer-heavy graph on a 64-bit target, and the structure-of-arrays layout is what makes "linear sweep over packed memory" literally true rather than aspirational.

### 5.5 Layout: Strict-Box

Constraints down, sizes up; inspired by Flutter's `RenderBox` model and mapped onto the ECS. A parent hands its child a `Constraint { min_w, max_w, min_h, max_h }`; the child returns one `Size`; the parent positions it and moves on. No solver, no iteration, no convergence. Each entity's `measure()` is called exactly once per pass; total work is O(N). Two modes: **Flow** (`.flow-col` / `.flow-row`, sequential stacking) and **Frame** (`.frame`, z-stack with absolute positioning). Sizing modifiers are `.w-N` (explicit), `.fill-w` (consume remaining space), and `.fit-w` (shrink to content), with height symmetric. Budgeted at roughly 2,400 lines of Zig, a target (§12),
and text measurement is a direct native call into the Trinity; there is no FFI inside the frame loop.

### 5.6 Paint: frame production

DirtyFlags decide *whether* a frame is produced and *which* entities re-run style, layout, and shaping. Paint itself then emits the **complete visible display list**, length-prefixed, tagged commands (`DrawRect`, `DrawTextRun`, `DrawImage`, `Clip`, …), into the current back slot, records damage rects from the dirty bounds, streams any newly rasterized glyphs into the atlas stream (§3.3) and stamps `atlas_head_required`, and publishes via the `latest` exchange. The slot never carries a partial list; "full list, stateless host" is the protocol, not a tendency.

Two implementation stages, one wire format:

- **First cut: full re-walk.** Paint traverses the entire visible tree on every produced frame. Correct over fast: the simplest implementation that satisfies the protocol, and at idle it costs nothing because no frame is produced at all.
- **Named optimization: retained command buffer.** The renderer keeps the previous frame's command buffer with per-subtree spans; a dirty frame re-emits only the dirty subtrees in place, and "full list" becomes one memcpy into the slot. Adopted only if the Phase-3 spike *measures* serialization as a real cost, the canonical case being a caret blink on a ten-thousand-glyph page. The change is invisible to the protocol and to the host.

Compositing layers are created only when genuinely needed (`opacity != 1`, a non-identity transform, an explicit z-lift); the default is flat paint, for cache friendliness.

### 5.7 Text: the Trinity, renderer-owned end to end

The single hardest subsystem. Eight stages, all inside the sandbox:

1. **Bidi** (UAX #9): SheenBidi
2. **Script itemization** into single-script runs
3. **Line-break analysis** (UAX #14): libunibreak
4. **Shaping**: HarfBuzz, per script-run × font
5. **Line layout**: first-fit greedy
6. **Visual reordering** by bidi level
7. **Rasterization**: FreeType, into the **renderer-owned** glyph atlas
8. **Paint**: `DrawTextRun` commands: packed glyph runs referencing atlas slots

The renderer owns shaping, rasterization, *and* atlas layout. It assigns the atlas slots and ships each newly rasterized bitmap **exactly once**, through the atlas stream of §3.3; the host's sole job is draining that stream into the GPU texture it mirrors, with the stream's tail cursor as the only acknowledgement. There is no UV round-trip and no request/response inside the paint path; it is a pure one-way producer flow on both legs. The security dividend is large: FreeType and HarfBuzz, historically among the most exploited surfaces in any browser, run inside the jail. Per-origin atlases cost some duplication across origins, accepted deliberately, since it also closes cross-origin glyph-cache timing channels, and blunted by the page sharing in §6.

Font files are `mmap`'d read-only, so the OS page cache shares them across every renderer process for free. Selection, caret, and IME hang off an `EditState` component; the IME bridges are IMK on macOS and IBus/Fcitx on Linux.

### 5.8 Images

The host fetches the bytes (it holds the network capability) and delivers them to the renderer via `FetchResult`. The renderer decodes them (the decoder, a classic attack surface, stays jailed) learns the intrinsic size locally for layout, and writes the pixels once into the staging region. The host uploads them to a GPU texture keyed by the renderer-assigned `resource_id` and replies `UploadDone` to recycle the staging space. Draw commands reference only the `resource_id`.

### 5.9 GPU: the `gpu.zig` seam ⚑

The host owns the GPU device and the render path, behind one non-negotiable seam: **`gpu.zig`**, a thin interface covering the small surface a 2D compositor needs: solid and rounded rectangles, glyph-run quads sampled from the atlas, image quads, clip/scissor, a second integer attachment for the ID buffer, and a one-pixel ID readback. Everything above this seam is backend-blind, which makes the decision below *reversible*: losing the bet later costs a backend, not the engine.

Two candidates sit behind the seam:

- **Hand-rolled backends.** Metal via the Objective-C runtime and a `CAMetalLayer` (tolerable), and Vulkan via the Wayland surface. Buys a near-zero dependency footprint and total control over the render path. Costs what Vulkan always costs, even for 2D: swapchain creation *and recreation on resize* (spicy on Wayland), semaphore/fence present-sync, descriptor plumbing for the atlas, and pipeline barriers plus a staging path for the ID-buffer readback that hit-testing performs on every click. That is real, recurring, one-person labor; and the few-megabyte size argument against the alternative is honestly weak next to it.
- **wgpu-native.** One C API yielding both Metal and Vulkan with battle-tested swapchain, synchronization, and readback correctness, for the price of a vendored binary and a foreign build step.

> **⚑ This is the one open decision in this document**, resolved by the
> Phase-3 spike; and the pass bar is deliberately not "clear a color." It is:
> correct swapchain **resize** and **present-sync on Wayland**, plus a
> **one-pixel ID-buffer readback that does not stall the frame**, demonstrated
> by each candidate inside its week. The honest prior going in: wgpu-native
> wins on person-time and correctness for a compositor whose thesis lies
> elsewhere; hand-rolled wins on dependency purity and control. Whichever
> lands, `gpu.zig` stays.

### 5.10 Hit testing: in the host, O(1)

The render pass writes an **ID buffer** (the entity id at each pixel) alongside the color framebuffer. An OS event reaches the host; the host reads one `u32` pixel at the event coordinates and sends `InputEvent { hit_entity, frame_seq, … }`; the renderer walks the parent chain from that entity and dispatches capture/bubble. No spatial index is needed, and the result is correct under overlap, clipping, masks, and transforms, anything the rasterizer drew correctly. The read is against the **last presented frame**: the scene may have advanced by the time the click lands, the same staleness every compositor accepts. `InputEvent` carries that frame's `seq`, so the renderer can detect it and compensate where it matters, a drag started on a moving target, for instance. And the pixel itself stores the **full generational entity handle**, never the bare index (at zero cost, since `Entity` is already that packed `u32`) so an entity freed and recycled inside the staleness window is caught by O(1) generation validation rather than mis-dispatching to its slot's new tenant. `frame_seq` says the frame is old; the generation says *this* entity is dead. Both checks exist because they catch different deaths.

### 5.11 Input and events

The renderer receives pre-resolved `InputEvent`s and dispatches capture → target → bubble through the parent chain. Handlers mutate signals; signals OR DirtyFlags bits onto the affected entities. Focus is tracked through the `Focusable` pool, and keyboard events route to the focused entity.

### 5.12 Luau: interpreter-only, compiled in the jail

Luau (the Lua 5.1 lineage hardened by Roblox to run millions of untrusted scripts) is the scripting runtime. Its interpreter is a hand-optimized register VM and the fastest Lua interpreter in existence; its gradual typing is a zero-runtime-cost tooling win; its sandboxing is a design center rather than an afterthought.

- **Interpreter-only.** Luau's optional native code generation stays off. The VM allocates zero executable memory, so the renderer sandbox denies `mmap(PROT_EXEC)` categorically. The classic JIT-versus-sandbox tension does not get managed here; it ceases to exist.
- **The compiler is the trust boundary.** Loading foreign bytecode is unsafe by Luau's own model, so Cara compiles `.luau` inside the renderer, always from source. Bytecode never crosses a trust boundary, and the compiler's attack surface lives in the jail where it belongs.
- **The VM is sandboxed**: `luaL_sandbox` with frozen globals and metatables, a stripped standard library (no `os`, `io`, `debug`, `package`, or raw `load*`), a `require()` resolving only against the page bundle, a memory ceiling (~32 MB by default) and a per-invocation instruction budget, and an incremental GC stepped against a per-frame budget so collection never causes a hitch.
- One VM per page; closing the page destroys it.
- **The host never caches or reloads compiled bytecode.** Compilation is always from source, inside the renderer; so a future page-load optimization that cached bytecode to disk and reloaded it (the obvious speed win) cannot quietly reintroduce the unsafe-deserialization vector Luau's own model warns against. This is the durable form of "bytecode never crosses the trust boundary."
- Luau is C++. It is vendored like the other native dependencies, built with `zig c++`, and spoken to through its C API at the FFI seam only.

### 5.13 Reactivity: the DirtyFlags binding table

Three primitives: `signal(initial)`, `compute(fn)`, and `bind(target, signal)`. Each `bind` records a statically known DirtyFlags mask:

| Property bound | DirtyFlags set on change |
|---|---|
| `style.color`, `style.bg`, `style.opacity` | `PAINT` |
| `style.width` / `height` / `padding` / `margin` | `LAYOUT` (cascades to ancestors) |
| `text.content` | `LAYOUT \| A11Y` |
| `children` (`for`, `show`) | `LAYOUT` on the parent, `A11Y` on the subtree |
| `clickable.handler` | none: a handler swap is free |
| `style.hidden` | `LAYOUT \| HITTEST` |

A batched scheduler walks the dirty entities in system order (style, then layout, then paint, then a11y) and each system clears only its own bit. A frame is produced *only* if some bit was set, which makes this table the event-driven render gate as well as the reactivity contract.

### 5.14 Standard component library

A locked, lowercase vocabulary: `box`, `text`, `input`, `textarea`, `checkbox`, `select`, `button`, `link`, `image`, `form`, `for`, `show`, `portal`, `scrollable`, `clickable`, `hoverable`, `focusable`. User-defined components are Capitalized. Performance-critical primitives are written in Zig; compositional ones (`form`, `for`, `show`, `portal`) are written in Luau and ship in the runtime directory.

### 5.15 Accessibility

An AccessKit-compatible projection: the renderer maps its scene graph into an AccessKit tree and sends it over IPC as `A11yUpdate`; the host bridges to the platform assistive-technology API (AX on macOS, AT-SPI on Linux). Each component contributes its semantic role automatically; authors never write ARIA. A `button` is a button; a `link` is a link. The component vocabulary *is* the semantic vocabulary.

### 5.16 Process architecture and security

- **Host** (privileged): window, OS event pump, GPU device, networking, storage, clipboard, accessibility bridge, hit-testing, process spawner.
- **Renderer** (one per origin, unprivileged): parser, scene graph, layout, paint, text, image decode, Luau.

The sandbox is enforced at spawn:

- **Linux**: a seccomp-BPF allowlist: `read`/`write` (the socket is plain stream framing), `recvmsg` (the host passes the staging-region fd via `SCM_RIGHTS`; the renderer can open nothing itself), `mmap` *without* `PROT_EXEC`, `futex`, and the small unavoidable tail (`munmap`, `exit_group`, `sigreturn`, clock reads, and `getrandom`: musl static init and Luau hash seeding both want entropy, and a missing `getrandom` is the classic silent sandbox breaker), denying `open`, `socket`, and `exec` outright. The renderer is statically linked against musl: smaller, a faster spawn, and no dynamic loader in the filter's threat model. Three completeness rules the allowlist must hold: if `mprotect` is ever needed (guard pages, GC) it carries the **same `PROT_EXEC` filter** as `mmap`: seccomp can inspect the `prot` scalar, so the no-exec guarantee is enforced, not assumed, or the renderer maps RW then `mprotect`s `+X`; the filter explicitly refuses the known syscall-filter *bypasses* even though allowlist-default already excludes them: `io_uring` (its submission queue performs reads, writes, and connects a syscall-level filter never sees), `userfaultfd` (userspace page-faulting is a heap-grooming primitive), `ptrace`, `process_vm_readv`/`writev`, and post-zygote `clone`/`fork`; and the filter is installed **before any thread spawns**, so it binds every thread the renderer ever runs rather than leaking through one created before the filter was in place.
- **macOS**: a Seatbelt profile via `sandbox_init`, an API Apple deprecated years ago and still ships, with no public replacement that fits sandboxing a spawned helper process (App Sandbox is entitlement- and distribution-coupled, not a child-process jail). Chromium relies on the same mechanism. Treat it as functional defense-in-depth that a future macOS could break; the primary mitigation on macOS is privilege minimization: the renderer never *holds* filesystem or network capabilities to abuse. The strong, supported jail is Linux seccomp.
- **fd hygiene**: `CLOEXEC` on everything; the renderer inherits exactly the shared-memory fds and the IPC socket.
- **Resource fencing.** Luau's ~32 MB ceiling bounds *script* memory, not the native renderer: a compromise `mmap`s freely, spins the CPU, and exhausts fds. Each renderer therefore runs under a cgroup memory + CPU cap and RLIMITs (address space, fd count), with a host watchdog that kills and restarts it on a `ProcessHealthcheck` timeout. (This is the DoS fence; the CI RSS budgets of §6 are about *our* footprint, a different concern.)
- **Sealed regions (Linux).** On Linux the shared regions are `memfd`s carrying `F_SEAL_SHRINK`, so the grow-only invariant (§3.3) is kernel-enforced and a renderer cannot shrink a region out from under a host read. Write-sealing is unavailable (the renderer must write the slots and staging) so this is partial by design; it closes the shrink half, and `ftruncate` is already absent from the allowlist. macOS has no `memfd`/seal equivalent (it uses `shm_open`), so there the grow-only guarantee rests on host-trust (the host owns the region and never shrinks it) rather than a kernel seal.
- Different origins run in different renderer processes, with no shared memory between them, separate atlases, and separate Luau VMs.

A renderer compromise (a HarfBuzz exploit, an image-decoder bug, a Luau VM escape) yields a process with no syscalls of consequence, no executable memory, no filesystem, no network, and a thirteen-message typed surface to the host. This is the entire reason the two-process split exists, and until it is enforced the architecture's central promise is unbacked.

**The trusted computing base, named honestly.** The architecture jails the renderer-side parsers that history has punished most (font shaping, rasterization, image decoding, script compilation) and that is the right instinct. But the host stays trusted, and inside it run vendored parsers that also touch hostile or untrusted bytes: **libcurl + HTTP/2 + TLS** parsing attacker-influenced bytes off the wire, **SQLite** parsing a possibly-corrupt on-disk database, the **GPU driver / wgpu-native** consuming command buffers, and **AccessKit**. A memory-safety bug in any of these is *direct host compromise*: it is not sandboxed, and network-facing parsers are among the highest-risk code that exists. So the trust gradient is partly inverted: some of the scariest parsing got jailed while other scary parsing sits in the crown. This is named rather than hidden, with two consequences. The host-side trusted parsers are kept as thin as the job allows; "minimal first-party code" (§1) does not shrink them, because the exposure is the irreducible *vendored* surface
in the *privileged* process. And a network-fetch broker that pushes TLS/HTTP parsing down into a less-privileged helper is on the table for the far horizon (§10) as the way to flatten the gradient; v1 ships with the TCB enumerated and the risk owned.

### 5.17 The trust boundary: host-side validation

§5.15 and §5.16 define the *shape* of the security boundary: two processes, the no-`PROT_EXEC` jail, the seccomp allowlist. This section defines the other half: crossing it safely. The renderer is the hostile input source the whole architecture posits: a HarfBuzz exploit, an image-decoder bug, or a Luau escape leaves a process running attacker-controlled native code that will lie in *every byte it is permitted to emit*. So "a thirteen-message typed surface" (§5.16) and "`@ptrCast` in place" (§3.1) are, on their own, an attack surface and a memory-corruption primitive. They become safe only under one contract: **every renderer-supplied byte (in a frame slot, the atlas stream, the cursor words, or an IPC envelope) is validated host-side against host-owned bounds before use, and the validation is robust to the bytes changing underneath it.** The renderer is treated as hostile across shared memory with exactly the rigor it is treated across IPC. That symmetry is what makes the two-process claim real rather than decorative.

**The display-list consumer is a validating parser, not a trusting cast.** The host still reads commands in place (it does not copy the frame out, because that is the performance thesis) but it trusts no field. Before use it enforces: `command_bytes` ≤ slot payload; every per-command advance stays within the remaining budget; the final command ends at or before the buffer end; every `DrawTextRun`'s glyph and advance counts fit the region it declares; and every *index* is range-checked against a host-owned bound: atlas slot `<` atlas capacity, `resource_id` ∈ the set the host has actually uploaded, every clip/scissor rect within the viewport. A malformed frame is a dropped frame and a killed renderer, never a corrupt host. The sharp case is a `DrawTextRun`'s per-glyph atlas indices: validating the *count* once is not enough, because a mutating producer can rewrite an index after the check, so each index is masked-to-capacity **at the point of use**, not merely bounds-checked at parse. That per-glyph masked indexing is precisely what the mutating-producer fuzz test must target.

**Robust to concurrent mutation: corruption-impossible bounds.** The producer holds write access to all three slots, so a compromised renderer can write the very slot the host is reading: validation cannot assume the bytes hold still (a classic time-of-check/time-of-use double-fetch). The discipline, chosen deliberately over copying so zero-copy survives: each field is read out of shared memory **exactly once** into a register or local and **never re-dereferenced**; all bounds are enforced on those locals; and the cursor arithmetic is written so that the worst case of a field mutating mid-read is **garbage pixels, never an out-of-bounds access**. Concretely: read `command_bytes` once, clamp it to the slot payload, iterate against the clamped local; read each command's `size` once into a local, check it against the remaining clamped budget, advance by the local, and never read that size from the slot again. The proven SPSC reasoning assumed a cooperative producer; this restores safety against a hostile one without a copy. It is more code, and it demands a test that fuzzes a *mutating* producer racing the consumer, both accepted: the performance thesis is kept and memory safety is not conceded.

**The cursor words and the slot index are adversarial.** `latest` carries the renderer-published `slot | dirty | gen`, so the slot index is attacker-chosen; it is masked to `[0, slot_count)` before any base address is computed. `atlas_head` is renderer-written, so `head -% tail` is clamped to atlas capacity before the host drains, and every atlas entry's slot rect is bounds-checked against the atlas dimensions and its byte length against the stream extent before the texture sub-upload. The wrapping-difference discipline (§3.3) was proven for a *trusted* SPSC; against a hostile producer the difference is an attacker-controlled length until the capacity clamp bounds it.

**Geometry is host-owned, and crosses no boundary at all.** An earlier draft put identity and geometry in a separate shm object the renderer mapped read-only. Rule 6 killed it. The invariant that matters is only that *the host never trusts a layout-defining value it read from renderer-reachable memory*, and that is satisfied by the host trusting its own copy: kernel-enforced read-only-ness was protecting the *renderer* from the *host*, a threat the model doesn't contain (the renderer already trusts the host for its entire input). So: slot geometry (size, count, offsets) is **comptime constants in the shared `frame.zig` module** both binaries build from one tree; the only in-band word is a magic|version stamp the host writes at creation and the *renderer* checks on map as a binary-skew guard, which the host never reads back. If geometry ever becomes dynamic, it travels host→renderer over IPC (the trusted direction) exactly as the staging region's size already rides in `Resize` (which also keeps `fstat` out of the seccomp allowlist; the renderer learns sizes from messages, not from statting fds). No third shm object, no extra fd, no extra seal. The one read-write shared word, `latest`, keeps its own cache line as before; and its slot index is still masked, because *that* word the renderer genuinely writes.

**IPC envelopes are validated and direction-checked.** The host rejects any envelope whose `tag` is outside the renderer→host subset: a renderer sending `SpawnRenderer`, `LoadPage`, `FrameTick`, `Resize`, or `UploadDone` is malformed and is killed, not dispatched. The `length` field is attacker-controlled, so it is capped and never used to size an allocation on faith, and no host-side array is indexed by the renderer's `seq` without a bound. `A11yUpdate` is structured renderer→host data consumed by the privileged AccessKit bridge, so its node counts, tree shape, and string lengths get the same validating parser the display list does.

**Speculation-safe on the hot paths.** Two mutually-distrusting principals share a machine, so a *branch* that bounds an attacker-controlled index is itself bypassable: the host can speculatively index past the bound, transiently read host memory, and leak it to the renderer through the shared cache (Spectre-v1, the canonical browser channel). The index-validation paths that touch attacker-controlled values therefore clamp with an arithmetic **mask**, not only a conditional branch, so a misprediction still reads in-bounds. This is a hardening-phase refinement, named here because it belongs to this contract.

### 5.18 Storage

A per-origin SQLite key-value store, owned by the host (only the host touches the filesystem). Renderers request reads and writes over IPC: `storage.get / set / delete / list`. The store a `StorageOp` reaches is bound to the **host-assigned** origin for that renderer (never an origin named in the message) so a compromised renderer cannot read another origin's data by claiming its identity. Keys are sanitized host-side (no traversal or escape into a neighbouring origin's namespace). Default quota is 10 MB per origin, user adjustable, and enforced host-side as a disk-DoS bound. There is no IndexedDB equivalent; data that wants a database is stored SQL-shaped through Luau.

### 5.19 WASM tier (slotted, not built)

A future affordance for applications that outgrow the component vocabulary:

```glyph
page { app src="myapp.wasm" .w-full .h-full }
```

The browser would instantiate a module, hand it a render surface scoped to that node's box, and route input into it with capability-restricted I/O. It is designed in so that adding it later is purely additive, and it is not built.

# 

## 6. Memory and Resource Discipline

**Allocation is architecture.** Every byte has a named lifetime and a named allocator, and no general-purpose allocator appears on any hot path.

| Lifetime | Allocator | Used for |
|---|---|---|
| One parse | `FixedBufferAllocator` over a 4×-source arena | Glyph descriptors |
| One frame | a fixed arena reset each frame, zero individual frees | paint scratch, shaping runs |
| One page | grow-only pools, generation-recycled | scene-graph SoA, atlas metadata |
| Process | a debug-leak-checked GPA | cold host paths only |
| Shared | page-aligned `mmap` | frame slots, staging (images + atlas stream) |

**Every clean page is shared across origins.** Font files and the Unicode tables are `mmap`'d read-only, so the page cache shares them across all renderers at no cost. When multi-origin work lands, renderers are spawned from a **zygote**: one pre-warmed renderer (Luau VM up, fonts mapped, common glyphs shaped) is `fork`'d per origin, and copy-on-write shares every clean page. **The zygote is a Linux mechanism.** On macOS, fork-without-exec is a tripwire, not a guarantee: the moment anything (including a vendored library) lazily initializes Objective-C or CoreFoundation, the child is undefined and modern macOS will abort it. The renderer being GUI-free pure compute and the fork happening before any thread exists are the right preconditions, but they are preconditions, not proof. macOS therefore falls back to plain `posix_spawn` (fast enough) and takes its sharing from the `mmap`'d fonts and the loader's shared text pages; a macOS zygote is attempted only if a startup audit shows zero ObjC/CF initialization in the renderer image. **Background origins freeze** (SIGSTOP or the cgroup freezer) so only the foreground renderer is ever hot.

Two security facts the zygote carries, stated so they don't surprise anyone at Phase 9. First, `fork`-without-`exec` means every Linux renderer inherits the zygote's exact memory layout, so **ASLR is shared across renderers**: an info-leak in one renderer is a layout leak into all of them. Chromium makes this same tradeoff knowingly for spawn speed and memory sharing; Cara does too, and names it. Second, the zygote must be **strictly origin-agnostic before the fork** (no per-origin bytes, cookies, or fetched content may ever touch it) or copy-on-write silently shares one origin's residue into another, breaking the per-origin isolation the fork exists to preserve cheaply.

**Budgets are features.** Explicit resident-set ceilings (host idle, renderer baseline, per-page marginal) are asserted in CI. A memory regression fails the build, TigerBeetle-style. "Least memory" stays true only if exceeding it breaks the build. Strings are interned once into a single buffer addressed by u32 handles, and everything visible is a u32 index into a packed pool.

**Idle is genuinely zero.** There is no frame loop and no timer tick while the page is clean. The only things that wake anyone are input, `FrameTick` during active animation, and IPC traffic.

# 

## 7. The Utility Vocabulary

Roughly 220 utilities, dot-prefixed, compiled into the binary as a perfect hash, and locked.

**Layout** `.flow-col .flow-row .frame .hidden` · **Sizing** `.w-{0..16} .w-full .w-screen .h-* .max-w-* .min-h-* .fill-w .fill-h .fit-w .fit-h` · **Alignment** `.align-{start,center,end,stretch} .justify-{start,center,end,between,around} .gap-{0..16}` · **Spacing** `.p-{0..16} .px-* .py-* .pt/pb/pl/pr-*`, the same for `.m-*` · **Typography** `.text-{xs..4xl} .bold .italic .underline .strikethrough .font-{sans,serif,mono} .text-{left,center,right} .leading-{tight,normal,loose}` · **Color** (12 palette × 9 shades) `.bg-color-N .color-N .border-color-N` · **Border and shape** `.border .border-{1,2,4} .rounded-{none,sm,md,lg,xl,full}` · **Shadow** `.shadow-{sm,md,lg,xl,none}` · **Cursor and overflow** `.cursor-{pointer,text,wait,not-allowed} .overflow-{hidden,scroll,visible}` · **Position** `.relative .absolute .top/left/right/bottom-N`

**Variants**, prefixing any utility: `.hover: .focus: .active: .sm: .md: .lg:`

Adding a utility is easy. Removing one after authors depend on it is impossible. The list is locked for that reason.

# 

## 8. What Cara Does Not Do

No HTML, CSS, or JavaScript rendering, not even partial. No DOM shim; the scene graph is the scene graph. No CSS-equivalent features: no flex-grow with explicit basis, no grid (nest flows), no flex-wrap, no min-content/max-content distinction, no aspect-ratio without explicit math, no floats, columns, or tables. No browser extensions in v1. No print or PDF. No WebRTC, WebSockets, Service Workers, IndexedDB, or ContentEditable. No sync, accounts, or cloud. No DRM. No telemetry. No marketplace. No JIT-compiled page scripts: the interpreter is the price of a `PROT_EXEC`-free jail, and Luau's interpreter makes that price cheap. No Windows, for now. And no Rust, no Cargo, and no second toolchain.

# 

## 9. Project Layout

```
cara/
├── build.zig                  # the one true build script (Wayland + Cocoa)
├── build.zig.zon
├── vendor/
│   ├── glfw/                  # window + input (Wayland on Linux, Cocoa on macOS)
│   ├── glfw.zig               # translate-c'd bindings
│   ├── luau/                  # scripting (C++, built with zig c++; C API at the seam)
│   ├── sheenbidi/             # UAX #9 (C)
│   ├── libunibreak/           # UAX #14 (C)
│   ├── harfbuzz/              # shaping (C++)
│   ├── freetype/              # rasterization (C)
│   ├── libcurl/               # HTTP/2 networking (C)
│   ├── sqlite/                # storage + cache (C)
│   └── accesskit/             # accessibility bridge (host-only)
├── src/
│   ├── host/                  # ── HOST PROCESS ──
│   │   ├── main.zig
│   │   ├── window.zig
│   │   ├── event_pump.zig
│   │   ├── gpu.zig            # the seam; the backend behind it is ⚑ (§5.9 spike)
│   │   ├── frame_exec.zig     # check+take newest slot, drain atlas stream, draw
│   │   ├── hittest.zig
│   │   ├── net.zig
│   │   ├── storage.zig
│   │   ├── a11y_bridge.zig
│   │   ├── ipc_thread.zig
│   │   └── spawn.zig
│   ├── renderer/              # ── RENDERER PROCESS ──
│   │   ├── main.zig
│   │   ├── glyph/             # target ~400 LOC, zero-alloc parser
│   │   │   ├── lexer.zig
│   │   │   ├── parser.zig
│   │   │   ├── markdown.zig   # u32 bitmask state + span emission
│   │   │   ├── arena.zig      # 4×source-sized arena
│   │   │   └── spawn.zig      # descriptor tree -> ECS
│   │   ├── style/             # perfect-hash utilities + resolver
│   │   ├── scene/             # entity, pool (sparse-set + flat vector), hierarchy, dirty
│   │   ├── systems/           # layout (Strict-Box), paint, frame_producer, animation
│   │   ├── text/              # trinity, bidi, linebreak, shape, line_layout, raster, atlas, edit
│   │   ├── image/             # decode -> staging
│   │   ├── luau/              # sandboxed VM, bindings
│   │   ├── reactivity/        # signal, compute, bind
│   │   ├── components/
│   │   └── a11y/
│   └── ipc/
│       ├── frame.zig          # frame-slot header + the latest-wins protocol
│       ├── protocol.zig       # envelope + the 13 messages
│       └── staging.zig        # staging: decoded images + the atlas stream
├── runtime/                   # Luau side: stdlib.luau, reactive.luau, components/
├── docs/                      # this document, the HLD, the diagrams
├── tests/
└── examples/                  # 01-hello, 02-counter, 03-todos, 04-blog
```

`zig build run` orchestrates the whole multi-process project from source.

# 

## 10. Roadmap: build up, never out

Each layer sits on a proven one.

1. **Frame slots.** The three-slot, latest-wins shared region: header, slot geometry, the `latest` word alone on its cache line, comptime layout asserts; publish/consume via the acquire-release exchange; a multi-frame stream proof; `FrameHeader` plus damage rects; 8-byte alignment; a unit-tested slot API.
2. **Wire protocols.** The draw-command format (`tag` + `size`, `DrawRect` first); the IPC socket, envelope, and thirteen messages; `FrameReady` (carrying `wants_tick`) / armed `FrameTick`; then kill the busy-wait, the host blocks on the socket and the IPC thread wakes the main loop with `glfwPostEmptyEvent()`, and prove 0% idle CPU with nothing dirty.
3. **Host renderer.** A GPU surface (`CAMetalLayer` on macOS, Wayland on Linux), framebuffer, and present; the ID buffer; an O(1) hit-test producing `InputEvent`; resize. *The §5.9 GPU spike resolves ⚑ here: pass bar per candidate: swapchain resize + present-sync on Wayland + a non-stalling one-pixel ID readback, plus the caret-blink serialization measurement from §5.6. Not "clear a color."*
4. **Text.** The renderer-owned glyph atlas and the full Trinity (SheenBidi → libunibreak → HarfBuzz → FreeType); the atlas stream with its monotonic cursor pair (§3.3, never bitmaps inside frames); the host mirroring the atlas texture; `DrawTextRun`.
5. **Renderer brain.** The ECS pools; the Glyph parser (the bitmask and arena specifications); style; Strict-Box layout; paint.
6. **Interactivity.** Luau, interpreter-only and sandboxed, compiled from source in the renderer; the reactivity primitives; event dispatch; the first components.
7. **Host services.** Networking (libcurl); storage (SQLite); clipboard; the AccessKit bridge; the image pipeline (decode-in-jail, staging, `UploadDone`).
8. **Security.** The renderer sandbox: seccomp-BPF denying `PROT_EXEC` and the bypass syscalls on Linux, Seatbelt via `sandbox_init` on macOS (deprecated API, defense in depth, see §5.16); the musl-static renderer; fd hygiene; enforced per-origin isolation. **And the trust-boundary contract (§5.17):** the host-side validating parser for frame slots, the atlas stream, the cursor words, and IPC envelopes, robust to a mutating producer; host-enforced origin + SSRF destination filtering on `Fetch`; storage origin-binding; per-renderer resource fencing (cgroup/RLIMIT/watchdog) and `F_SEAL_SHRINK` regions. This phase is the one that makes the two-process split *true*.
9. **Memory and cross-platform.** `mmap`'d shared fonts; per-subsystem allocator strategy; CI-enforced RSS budgets; the zygote fork (Linux; macOS only if the §6 fork-safety audit passes) and background freeze; Wayland and Cocoa validation; documentation kept in sync as code lands.
10. **Far horizon.** Full page lifecycle, multi-tab, animation on `FrameTick`, network maturity, GPU batching, a Linux futex on `latest`, atlas eviction (itself an ordered stream entry, an overwrite is a write, and never of a slot an in-flight frame references), a network-fetch broker that pushes TLS/HTTP parsing out of the trusted host to flatten the TCB gradient (§5.16), devtools.

# 

## 11. The Mantra

- _One language for structure (Glyph)._<br />
- _One language for the engine (Zig)._<br />
- _One vocabulary for style (utilities)._<br />
- _One layout algorithm (Strict-Box)._<br />
- _One data structure for everything visible (the scene graph)._<br />
- _One reactive primitive (signal)._<br />
- _One render path (scene graph → display list → frame slot → GPU)._<br />
- _One pool that drives all incremental work (DirtyFlags)._<br />
- _One sandbox boundary that defines the security model (the renderer process)._<br />
- _One channel for bulk data (shared memory) and one for control (IPC)._<br />
- _One atomic word that publishes a frame (`latest`)._<br /> Latest frame wins._<br />
- _One stream, for the one thing a skipped frame must never drop (the atlas)._<br />
- _One bitmask for markdown state._<br /> One arena per parse._<br />
- _No pointers across the boundary._<br />
- _No executable memory in the jail._<br />
- _The renderer is hostile; the host bounds every byte it sends._<br />
- _No work while idle._<br />
- _No accreted legacy in any layer._<br />
- _One person should be able to hold this in their head._ 

If a proposal violates this, the proposal is wrong.
