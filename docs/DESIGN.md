# utilz implementation notes

This document preserves the implementation-level decisions cited by the Zig
sources. The product is a standalone multicall userland. Applets talk to the
world through `sys.Impl`. Behavior is compared to uutils 0.9.0.

## 1. Scope

utilz ships engines plus applets over an attachable `sys.Impl`. Embedders
attach a memory or POSIX backend (or their own) and call `run(*Ctx) u8`.
The roster in `src/registry_data.zig` is the authoritative inventory.

The roster in `src/registry_data.zig` is the authoritative inventory. Each applet's leading comment
states its implemented option and behavior scope; this section replaces the deleted milestone inventory
those comments historically cited.

## 2. Parity policy

Observable output, exit status, option precedence, and failure behavior are parity surfaces. Small
diagnostic differences may be accepted when host-dependent or hardware-specific behavior cannot exist
on a given backend; those exceptions must be stated beside the implementation and pinned by tests. Debug
or hardware-capability chatter may be a no-op when it cannot change the requested operation.

Concrete scope rulings and oracle observations remain beside the affected applet and its regression
tests. This section replaces the deleted parity ledger as their common policy, not as a duplicate list.

Text processing is byte-oriented unless an applet explicitly documents Unicode behavior. The shared
line model accepts CRLF, strips one trailing `\r`, and still yields an unterminated final line.

## 3. Dependency boundaries

- Applets may import `core/`, `engines/`, `sys/`, and shared types; applets never import one another.
- Engines contain reusable algorithms and normally avoid applet policy. An engine may use `sys` or
  `Ctx` when the reusable operation intrinsically owns I/O, as in checksum verification.
- Only `sys/` talks to the attached `sys.Impl`. There are no applet-local extern blocks.
- Shipped code avoids high-level `std.fs` / `std.Io` / `std.fmt` when the `sys` facade or
  a small local implementation is sufficient; this is a wasm-size constraint, not a style preference.

## 4. System boundary

### 4.1 Applet-facing sys API

`sys/root.zig` free functions delegate to the attached `sys.Impl`. Mem and
POSIX backends ship in this repo. A consumer may attach its own backend.
Pure native tests exercise engine modules and applets after attach. `sys/types.zig`
owns the shared fd, process, stat, signal, polling, and error types. Applets consume this typed API
rather than raw ABI values.

Arguments cross `spawn` as one NUL-separated blob without a required trailing NUL. `waitpidNohang`
returns `null` when a child has not changed state. Kernel `unlink` removes files and empty directories;
recursive deletion therefore empties a directory before unlinking it.

### 4.2 Backends

`sys/mem.zig` is an in-memory `sys.Impl`. `sys/posix.zig` is the host backend.
Network calls return `ENOSYS` on both. A consumer may attach its own
backend with the same `sys.Impl` surface.

### 4.3 Environment

`core/envfs.zig` is an optional `/env` file adapter. It is not the default host
environment. `printenv` / `env` / `which` / `pwd -L` use it when `/env/<NAME>`
exists. Mem and POSIX backends do not create `/env` unless the embedder does.
`pwd` without a usable `/env/PWD` uses `sys.getcwd`.

## 5. Program structure

### 5.1 One registry

`registry_data.zig` is the only applet roster. It drives dispatch, help/version behavior, generated
image symlinks, and `mc_applets` metadata. Adding or removing an applet anywhere else is incomplete.
Function references in the registry provide the dead-code roots; there is no secondary hand list.

### 5.2 Applets and engines

An applet owns command-line policy and user-facing diagnostics. Reusable parsing and algorithms live
in `core/` or `engines/`. This keeps similar commands behaviorally aligned without coupling their
entrypoints.

### 5.3 Context and allocation

Every applet receives `*Ctx`: allocator, argv, stdio, and the shared output/error path. The process
allocator is commonly an arena released wholesale at exit, so builders copy values instead of relying
on mutable aliasing. Streaming applets bound their buffers; explicitly whole-buffer engines document
that choice and inherit a documented memory budget.

## 6. Shared facades

The reusable facades are deliberately small:

- `textio`: CRLF-tolerant line iteration and common operand loops;
- `fsutil`: lexical paths, canonicalization, recursive copy/remove, and symlink policy;
- `proc`: argv-blob construction and EINTR-safe spawn/wait helpers;
- `sizes`: shared human-size parsing;
- `spool`: bounded memory with optional spill;
- `fmtnum`: the C-style formatting subset used by `printf`-family applets; and
- `civil`: UTC civil-time conversion for stat and date rendering.

### 6.1 Command-line parsing

`core/cli.zig` handles the common short/long flag grammar, precedence, help, and operands. Applets
hand-parse when operands are ambiguous with options, option meaning depends on position, or the grammar
needs `allow_hyphen_values`/trailing arguments that the shared shape cannot express cleanly.

### 6.2 Help

Each applet provides structured, agent-readable help through `core/help.zig`. Help text and dispatch
metadata come from the same registry entry as the executable function.

## 7. Engines

### 7.1 Regex

The shared regex engine is a pure-Zig Pike VM. It is reusable by grep, sed, awk, and future applets;
word-boundary assertions were added as part of the grep milestone (M3).

### 7.2 Glob

Glob matching uses iterative backtracking with explicit pathname and dotfile rules. It does not call
the host filesystem or a libc matcher.

### 7.3 Hashing

The hash engine owns digest implementations, checksum-line parsing, and the shared compute loop used
by the checksum applets. Algorithm selection and CLI presentation remain applet policy.

### 7.4 Codecs

The codec engine owns RFC 4648 base16/base32/base32hex/base64/base64url behavior. Base applets may
duplicate a tiny option declaration, but not the codec implementation.

### 7.5 Compression and archives

Compression/archive engines use a whole-buffer model bounded by a documented memory budget. Tar writes
explicit POSIX ustar headers. Zip parses and writes its in-memory records directly rather than pulling
in file-oriented `std.Io` machinery. gzip emits a deterministic header with mtime zero and no filename.
No zip64 support is claimed.

### 7.6 Diff and magic

Diff uses a Myers line algorithm. File detection uses a compact signature table plus explicit text,
JSON, XML, HTML, and shebang heuristics. Both return small result types and leave CLI rendering to the
applet.

### 7.7 Sort matrix

Sort stores input bytes once and sorts line offset/length records. Global comparison flags are inherited
by keys unless a key overrides them. External sorting uses bounded batches and the shared spool facade.

### 7.8 Date and calendar

Date parsing/formatting is proleptic Gregorian and supports UTC plus fixed numeric offsets. Named
IANA zones and locale-dependent calendar behavior are outside the contract.

## 8. Memory model

Streaming filters use bounded read/write buffers. Algorithms that require a global view—compression,
archives, some sort/diff modes—may read a complete input, but must state that fact and remain subject to
a documented memory budget. Use a spill directory when an algorithm supports it.

## 11. Size rules

1. Prefer shared facades and engine code over applet-local copies of nontrivial logic.
2. Do not import host-oriented filesystem/IO stacks into shipped wasm merely for convenience.
3. Keep diagnostics on the minimal formatter unless an engine truly requires richer formatting.

These are enforced by the built artifact's size budget as well as review.

## 14. Adapter checklist

R1: every ABI value comes from the generated contracts. The mc adapter translates types and calling
conventions only. It must preserve all known errnos, use the generated stat layout, and keep unsupported
values explicit (`EUNKNOWN`) rather than guessing.
