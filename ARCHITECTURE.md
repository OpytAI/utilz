# Architecture

utilz is a Unix userland in Zig. Applets take a `*Ctx` and issue syscalls
through `sys.Impl`. The library does not embed an operating system.

Engines, `sys.Impl` attach, mem and POSIX backends, and the applet
registry live in this tree.

## Design principles

- The world boundary is `sys.Impl`.
- Keep `fn run(ctx: *Ctx) u8`. Do not put `*sys.Impl` on `Ctx`.
- Keep the core free of shcore labels.
- Treat uutils 0.9.0 as the behavior oracle, not a crate.
- Keep network applets optional. Mem and POSIX backends may return `ENOSYS`.

## Dependency direction

```text
sys types / errno
        |
        v
sys.Impl + attach / detach
        |
        v
core facades, engines
        |
        v
applets + registry
        |
        v
utilz root
```

utilz must not depend on shcore. `split --filter` and similar spawn a command
string through `sys.spawn`.

A consumer attaches its own `sys.Impl`. This repo ships mem and POSIX
backends. It does not ship a guest-kernel backend.

## Major boundaries

| Area | Location | Responsibility |
|------|----------|----------------|
| Public root | `src/root.zig` | Re-exports engines, registry, sys |
| Sys | `src/sys/` | Types, `Impl`, attach, mem, posix |
| Engines | `src/engines/` | Algorithms (pure first, I/O after attach) |
| Applets | `src/applets/` | `run(*Ctx) u8` |
| Oracle pin | `UUTILS_PIN.md` | uutils 0.9.0 |

## `sys.Impl`

Free functions in `sys/root.zig` delegate to a process-scoped attached
`sys.Impl`. `attach` / `detach` are single-threaded. Only the outermost
embedder calls them; attach is not refcounted. Nested attach of a
different impl panics. A nested applet `run` on the same impl does not
re-attach. Mem implements files and process subset. Net/http return
`ENOSYS`.

Public consume labels are `@utilz//:utilz` and `@utilz//src:lib`. Leaf
packages under `src/sys` and `src/engines` are not separate Bazel targets.

## Verification

Bazel is the only supported build and test entry point. See
[`docs/TESTING.md`](docs/TESTING.md) and [`docs/GATES.md`](docs/GATES.md).
