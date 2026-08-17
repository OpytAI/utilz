# uutils reference pin

| Field | Value |
|-------|--------|
| Repository | https://github.com/uutils/coreutils |
| Pin type | release tag |
| Pin | `0.9.0` |
| Published | 2026-05-30 |
| Decision date | 2026-08-17 |
| Role | Behavior oracle (not a crate dependency) |

## Policy

Prefer the latest **release** if it is not older than 6 months.
If the latest release is older than 6 months, pin the latest commit on the default branch instead.

Record every pin change here (old pin, new pin, date).

## Decision notes (2026-08-17)

- Latest suitable release at decision time: `0.9.0` (published 2026-05-30).
- Age relative to decision date: under 6 months.
- Action: pin release tag `0.9.0` (not floating main).
- utilz is a Zig implementation. Do not link the uutils crate. Do not vendor the uutils tree.
