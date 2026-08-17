#!/usr/bin/env bash
set -euo pipefail
# Light inventory: required runfiles exist.
root="${TEST_SRCDIR:-.}"
need=(
  LICENSE
  NOTICE
  README.md
)
missing=0
for rel in "${need[@]}"; do
  if ! find "${root}" -name "$(basename "${rel}")" | grep -q .; then
    echo "missing ${rel}" >&2
    missing=1
  fi
done
exit "${missing}"
