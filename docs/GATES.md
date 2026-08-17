# Acceptance checks

Run acceptance checks through Bazel. Default tests must not use the network
or the system Zig installation.

```bash
bazel build //...
bazel test //...
```

The workspace `.bazelrc` configures hermetic actions and the Zig compiler
cache. Set a local Bazel output root in ignored `user.bazelrc`.

## Targets

| Target | Purpose |
|--------|---------|
| `//:utilz` | Public library alias |
| `//src:lib` | Library build |
| `//src:utilz_test` | Engines and attach tests |
| `//data:goldens_test` | Applet goldens versus `data/goldens/` |
| `//src:utilz` | Host multicall |
| `//check:all` | Light inventory and golden smoke |

## Review expectations

- Review changes to expected results as carefully as source changes.
- Keep fixtures small and record their origin.
- Do not fetch fixtures during a build or test.
- Run `bazel build //...` before merging scaffold changes.
- Name the applet backend `sys.Impl`.
