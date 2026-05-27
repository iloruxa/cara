# Marauder

A browser that refuses to render the current web.

The web is what three decades of standards committees and ad-funded browser vendors built when no one was paying attention. HTML, CSS, and JavaScript were not designed for the people writing pages. They were designed to keep the people who own the rendering engines in business. Marauder is what happens when you stop accepting that as the only option.

Pages on Marauder are written in **Glyph** — a small declarative markup language with no quirks mode, no parser-as-state-machine, and no thirty years of accumulated compatibility tax. Behavior is scripted in **Lua**. Layout is constraint-propagated and runs in a single tree walk. The renderer lives in a sandboxed process and talks to the host through shared memory. There is no DOM. There is no JavaScript runtime. There is no telemetry, no marketplace, no extension store, and no opinion about what your homepage should be.

This repository contains the entire project — the rendering engine, the browser built on it, and the IPC layer between them. One language for the engine, one for behavior, one for documents. Small enough that one person can read all of it.

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for how it actually works.

---

```
git clone <repo-url>
cd marauder
zig build run
```

(Once Phase 0 lands. The work is starting.)
