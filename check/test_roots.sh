#!/usr/bin/env bash
set -euo pipefail
root=""
if [[ -n "${TEST_SRCDIR:-}" ]]; then
  root="${TEST_SRCDIR}"
fi
bases=()
[[ -n "${root}" ]] && bases+=("${root}")
bases+=("$(cd "$(dirname "$0")/.." && pwd)")

for base in "${bases[@]}"; do
  test_root=""
  if [[ -f "${base}/src/utilz_test.zig" ]]; then
    test_root="${base}/src/utilz_test.zig"
  else
    test_root="$(find "${base}" -name 'utilz_test.zig' 2>/dev/null | head -n 1 || true)"
  fi
  [[ -n "${test_root}" && -f "${test_root}" ]] || continue
  src_dir="$(dirname "${test_root}")"
  missing=0
  for f in "${src_dir}"/*_test.zig; do
    basef="$(basename "${f}")"
    [[ "${basef}" == "utilz_test.zig" ]] && continue
    if ! grep -q "${basef}" "${test_root}"; then
      echo "utilz_test.zig does not import ${basef}" >&2
      missing=1
    fi
  done
  exit "${missing}"
done
echo "utilz_test.zig not found" >&2
exit 1
