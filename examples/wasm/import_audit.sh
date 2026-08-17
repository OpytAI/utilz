#!/usr/bin/env bash
set -euo pipefail
root="${TEST_SRCDIR:-.}"
tool="${root}/_main/examples/wasm/wasm_imports"
wasm="${root}/_main/examples/wasm/cat_ls"
if [[ ! -x "${tool}" ]]; then
  tool="${root}/examples/wasm/wasm_imports"
fi
if [[ ! -e "${wasm}" ]]; then
  wasm="${root}/examples/wasm/cat_ls"
fi
if [[ ! -x "${tool}" ]]; then
  echo "wasm_imports not found" >&2
  ls -la "${root}" "${root}/_main/examples/wasm" 2>&1 || true
  exit 1
fi
if [[ ! -e "${wasm}" ]]; then
  echo "cat_ls wasm not found" >&2
  exit 1
fi
exec "${tool}" "${wasm}" utilz_cat utilz_ls utilz_init
