#!/usr/bin/env bash
set -euo pipefail
# Each golden dir has argv.txt + expected.txt. Contents must match the
# cases in data/goldens_test.zig (oracle strings below).
root=""
if [[ -n "${TEST_SRCDIR:-}" ]]; then
  root="${TEST_SRCDIR}"
fi
bases=()
[[ -n "${root}" ]] && bases+=("${root}")
bases+=("$(cd "$(dirname "$0")/.." && pwd)")

want_echo_argv=$'echo hello\n'
want_echo=$'hello\n'
want_printf_argv=$'printf %s hi\n'
want_printf='hi'
want_cat_argv=$'cat /tmp/f\n'
want_cat=$'abc\n'
want_b64_argv=$'base64 /tmp/h\n'
want_b64=$'aGVsbG8=\n'

found=0
for base in "${bases[@]}"; do
  mapfile -t dirs < <(find "${base}" -type d -path '*/goldens/*' 2>/dev/null || true)
  for dir in "${dirs[@]}"; do
    [[ -d "${dir}" ]] || continue
    found=1
    [[ -f "${dir}/argv.txt" ]] || { echo "missing argv.txt in ${dir}" >&2; exit 1; }
    [[ -f "${dir}/expected.txt" ]] || { echo "missing expected.txt in ${dir}" >&2; exit 1; }
    name="$(basename "${dir}")"
    case "${name}" in
      echo_hello)
        printf '%s' "${want_echo_argv}" | cmp -s - "${dir}/argv.txt" || {
          echo "${dir}/argv.txt != echo hello" >&2
          exit 1
        }
        printf '%s' "${want_echo}" | cmp -s - "${dir}/expected.txt" || {
          echo "${dir}/expected.txt != echo hello" >&2
          exit 1
        }
        ;;
      printf_hi)
        printf '%s' "${want_printf_argv}" | cmp -s - "${dir}/argv.txt" || {
          echo "${dir}/argv.txt != printf %s hi" >&2
          exit 1
        }
        printf '%s' "${want_printf}" | cmp -s - "${dir}/expected.txt" || {
          echo "${dir}/expected.txt != printf hi" >&2
          exit 1
        }
        ;;
      cat_abc)
        printf '%s' "${want_cat_argv}" | cmp -s - "${dir}/argv.txt" || {
          echo "${dir}/argv.txt != cat /tmp/f" >&2
          exit 1
        }
        printf '%s' "${want_cat}" | cmp -s - "${dir}/expected.txt" || {
          echo "${dir}/expected.txt != cat abc" >&2
          exit 1
        }
        ;;
      base64_hello)
        printf '%s' "${want_b64_argv}" | cmp -s - "${dir}/argv.txt" || {
          echo "${dir}/argv.txt != base64 /tmp/h" >&2
          exit 1
        }
        printf '%s' "${want_b64}" | cmp -s - "${dir}/expected.txt" || {
          echo "${dir}/expected.txt != base64 hello" >&2
          exit 1
        }
        ;;
      *)
        echo "unknown golden ${dir}" >&2
        exit 1
        ;;
    esac
  done
  if [[ "${found}" -eq 1 ]]; then
    echo "goldens ok"
    exit 0
  fi
done
echo "no goldens found" >&2
exit 1
