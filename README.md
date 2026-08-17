<div align="center">
  <h1>utilz</h1>

  <p><strong>Unix utilities, written for Zig.</strong></p>

  <p>
    A pure-Zig multicall userland and the engines behind it.<br>
    Applets take a <code>*Ctx</code> and talk to the world through <code>sys.Impl</code>.
  </p>

  <p>
    <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16-f7a41d">
    <img alt="uutils 0.9.0 oracle" src="https://img.shields.io/badge/uutils-0.9.0%20oracle-dea584">
    <img alt="Native and WebAssembly" src="https://img.shields.io/badge/targets-Native%20%7C%20Wasm-654ff0">
    <img alt="Built with Bazel" src="https://img.shields.io/badge/build-Bazel-43a047">
  </p>

  <p>
    <a href="#why-utilz">Why utilz</a> ·
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

Applets issue syscalls through `sys.Impl`. They do not embed an OS. The
behavior oracle is [uutils 0.9.0](https://github.com/uutils/coreutils). See
[`UUTILS_PIN.md`](UUTILS_PIN.md). That pin is a comparison target, not a crate
dependency.

## Capabilities

- **Engines** — regex, glob, hash, sort, datetime, diff, archives, and
  awk/jq/sed subsets.
- **Applets** — `run(*Ctx) u8` over an attached `sys.Impl`.
- **Pluggable backend** — `sys.attach` / `sys.detach` with mem and POSIX
  implementations. Network applets return `ENOSYS` on those backends.

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
| `//data:goldens_test` | Applet goldens versus `data/goldens/` |
| `//check:all` | Light inventory and golden smoke |

The repository `.bazelrc` selects hermetic build settings. Bazel uses its
platform default output root. A developer can set a machine-specific output
root in the ignored `user.bazelrc` file.

## Project status

utilz is a standalone userland. Attach a `sys.Impl`, then call
`registry.find(name).run(ctx)`.

Start with the documents that match your task:

| Document | What it covers |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | `sys.Impl`, engines, and dependency direction |
| [`docs/TESTING.md`](docs/TESTING.md) | Test layout and local verification |
| [`docs/GATES.md`](docs/GATES.md) | Acceptance checks |
| [`UUTILS_PIN.md`](UUTILS_PIN.md) | Behavior-oracle pin |

## Integration

Depend on `@utilz//:utilz`, attach a `sys.Impl`, and call `run(*Ctx) u8`.
This repository does not depend on shcore.
