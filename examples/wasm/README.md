# Freestanding WebAssembly: cat/ls over mem

This example compiles selected applets against the memory `sys.Impl`.
The module must import nothing.

```sh
bazel build //examples/wasm:cat_ls
bazel test //examples/wasm:import_audit
```

The audit prints uncompressed size and import count.
