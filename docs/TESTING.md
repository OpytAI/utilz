# Testing conventions

utilz tests are Bazel `zig_test` targets. Keep tests hermetic and
deterministic. Do not use the network or the host file system unless the
package under test is a POSIX backend.

## Layout

| Test type | Location | Bazel shape |
|-----------|----------|-------------|
| Unit | Co-located `test` blocks next to engines and applets | `//src:utilz_test` |
| Goldens | `data/goldens/` | `//data:goldens_test` |
| POSIX spawn | `src/sys/posix_spawn_test.zig` | `//src:posix_spawn_test` |
| HTTP wrapper | `src/sys/http_test.zig` | `//src:http_test` |

Production `zig_library` targets must not depend on test-only packages.
POSIX spawn and HTTP tests live under `src/sys/` so the library glob does
not pick them up.

## Current suite

`//src:utilz_test` runs engine vectors, attach tests, the `--help` roster
sweep, and fail-closed net hooks.
`//data:goldens_test` scans `data/goldens/` at runtime via runfiles.
Each case is `data/goldens/<name>/` with `argv.txt` and `expected.txt`.
Optional: `stdin.txt`, `expected_status.txt`, `epipe.txt`, and a `files/`
tree planted onto the mem FS (`files/tmp/h` → `/tmp/h`; skip `.keep`).
`//src:posix_spawn_test` execs host `/bin/true` and `/bin/echo`.
`//src:http_test` uses a loopback responder only.
Mem `env FOO=bar cmd` must leave `/env` in place; POSIX spawn tests keep
the host overlay.

`examples/embed/` is a second Bazel module. From that directory:

```bash
bazel test //... --override_module=utilz=$(realpath ../..)
```

Isolated-min options must not analyze `wget` / `wscat`.

POSIX tests may use the host filesystem. They must not use the public
internet. If `/bin/true`, `/bin/echo`, `/bin/cat`, or `/usr/bin/env` is
missing, the posix suite fails (it does not skip). Host temp paths use
`/tmp/utilz-posix-<pid>-<seq>`. Capture applet stdout with `Ctx` pipes;
do not use fd 0 as a buffer. Default mem HTTP stays `ENOSYS`, including
`http://127.0.0.1/`. `env -i` / `-u` use an in-process `/env` overlay, not
`mkdir /env` on the host.

## Running tests

```bash
# Complete repository suite
bazel test //...

# Named acceptance suite
bazel test //check:all
```

Use Bazel with the repository's rules_zig toolchain. Do not use the system
Zig compiler as a substitute for these tests.

## Review

Review golden expected files as carefully as source. Keep fixtures small.
Do not fetch during a build or test. Run `bazel test //...` before merging
behavior changes.
