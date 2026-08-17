# Testing conventions

utilz tests are Bazel `zig_test` targets. Keep tests hermetic and
deterministic. Do not use the network or the host file system unless the
package under test is a POSIX backend.

## Layout

| Test type | Location | Bazel shape |
|-----------|----------|-------------|
| Unit | Co-located `test` blocks next to engines and applets | A `zig_test` in the same Bazel package |
| Goldens | `data/goldens/` | Invoked by check targets |

Production `zig_library` targets must not depend on test-only packages.

## Current suite

`//src:utilz_test` runs engine vectors and attach tests.
`//data:goldens_test` runs applet goldens versus uutils 0.9.0 behavior.

## Running tests

```bash
# Complete repository suite
bazel test //...

# Library build
bazel build //:utilz
```

Use Bazel with the repository's rules_zig toolchain. Do not use the system
Zig compiler as a substitute for these tests.
