<div align="center">
  <h1>utilz</h1>

  <p><strong>Unix tools you can embed.</strong></p>

  <p>
    Call <code>cat</code>, <code>grep</code>, <code>sort</code>, and the rest over files,<br>
    memory, or your own backend. Same applets. You choose where I/O goes.
  </p>

  <p>
    <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16-f7a41d">
    <img alt="uutils 0.9.0 oracle" src="https://img.shields.io/badge/uutils-0.9.0%20oracle-dea584">
    <img alt="Native and WebAssembly" src="https://img.shields.io/badge/targets-Native%20%7C%20Wasm-654ff0">
    <img alt="Built with Bazel" src="https://img.shields.io/badge/build-Bazel-43a047">
  </p>

  <p>
    <a href="#why-utilz">Why utilz</a> ·
    <a href="#first-program">First program</a> ·
    <a href="#capabilities">Capabilities</a> ·
    <a href="#build">Build</a> ·
    <a href="#project-status">Status</a> ·
    <a href="./ARCHITECTURE.md">Architecture</a>
  </p>
</div>

---

## Why utilz

Unix utilities are useful beyond a guest image. Applications need `cat`,
`grep`, `sort`, and archive engines over memory, POSIX, or a custom backend.
utilz brings those engines and applets into Zig without a WASI libc and
without embedding an operating system.

Applets issue I/O through a syscall table you attach once. They do not embed
an OS. Behavior is compared to
[uutils 0.9.0](https://github.com/uutils/coreutils). See
[`UUTILS_PIN.md`](UUTILS_PIN.md). That pin is a comparison target, not a crate
dependency.

## First program

On a POSIX host:

```sh
bazel run //src:utilz -- ls .
```

`utilz ls`, `utilz cat`, and the rest are the same binary. Attach a different
backend when you want those applets to read memory instead of the host
filesystem.

## Capabilities

- **Engines** — regex, glob, hash, sort, datetime, diff, archives, and
  awk/jq/sed subsets.
- **Applets** — the usual suspects (`ls`, `cat`, `grep`, `sort`, `tar`, …)
  over the attached backend.
- **Pluggable backend** — memory and POSIX implementations. POSIX spawn execs
  host processes. Network applets return `ENOSYS` on those backends. An
  opt-in HTTP wrapper speaks loopback only; `wscat` stays `ENOSYS`.

## Build

utilz uses Bazel, rules_zig, and a hermetic Zig 0.16.0 toolchain.

```sh
bazel build //...
```

Useful targets:

| Target | Purpose |
| --- | --- |
| `//:utilz` | Public library |
| `//src:lib` | Same library (leaf label) |
| `//src:utilz` | Host multicall (`utilz ls .`) |
| `//src:utilz_test` | Engines and attach tests |
| `//src:posix_spawn_test` | Host spawn, xargs/env/find |
| `//src:http_test` | Loopback fetch/wget |
| `//data:goldens_test` | Applet goldens versus `data/goldens/` |
| `//check:all` | Named acceptance suite |

The repository `.bazelrc` selects hermetic build settings. Set the Bazel
output root and Zig compiler cache in the ignored `user.bazelrc` file.

## Project status

utilz is a standalone userland. Attach a backend, then look up an applet by
name and run it.

| Document | What it covers |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Backends, engines, and dependency direction |
| [`docs/TESTING.md`](docs/TESTING.md) | Test layout and local verification |
| [`UUTILS_PIN.md`](UUTILS_PIN.md) | Behavior-oracle pin |

Depend on `@utilz//:utilz`, attach a backend, and run applets. This repository
does not depend on shcore.

Project-owned code is Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
