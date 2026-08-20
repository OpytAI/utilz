# uutils reference pin

| Field | Value |
|-------|--------|
| Repository | https://github.com/uutils/coreutils |
| Pin | release tag `0.9.0` (2026-05-30) |
| Role | Behavior oracle (not a crate dependency) |

Prefer the latest release if it is not older than 6 months. Otherwise pin
the latest commit on the default branch. Record the old pin, new pin, and
date here.

When adding a golden under `data/goldens/`, capture stdout/status from this
pin, or from a documented deviation in the applet's leading comment. Do not
fetch during the build.

Do not link the uutils crate. Do not vendor the uutils tree.
