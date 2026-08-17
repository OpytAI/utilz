# AGENTS.md

This file gives the rules for work in this project. Read this file before you change code.

## Project purpose

**utilz** is Unix utilities in Zig.

The tagline is **Unix utilities, written for Zig.** The product is engines
plus applets plus a backend-agnostic `sys.Impl`. Applets issue syscalls.
They do not embed an OS.

Use **uutils 0.9.0** as the behavior oracle. See [`UUTILS_PIN.md`](UUTILS_PIN.md).
Do not link the uutils crate. Do not invent a different utility model.

This repository does not depend on shcore.

## Repository structure

This project uses a bare git repository and worktrees.

```
utilz.git/                bare repository (shared object store, no working tree)
utilz-master/             worktree: master
utilz-develop/            worktree: develop
utilz-<name>/             worktree: feature or hotfix branch (temporary)
```

### Layout rules

- Never work inside the bare repository directory. It has no working tree.
- Each worktree checks out exactly one branch. Two worktrees must not share one branch.

## Reference pin (uutils)

Pin the uutils behavior oracle. Do not float on an untracked tip without a
record.

### How to choose the pin

1. Prefer the **latest release** of uutils/coreutils.
2. If that release is **not older than 6 months**, pin that release tag.
3. If that release is **older than 6 months**, pin the **latest commit** on
   the default branch instead.
4. Record the pin in [`UUTILS_PIN.md`](UUTILS_PIN.md).

### When the pin changes

- Change the pin only on purpose.
- After a pin change, update goldens so Bazel checks stay correct.
- Note the old pin and the new pin in the commit message or plan that
  performs the bump.

## Build system

Build and test only with **Bazel** and **rules_zig**. Use the Zig **0.16**
toolchain that Bazel provides. Do not use the system `zig` binary for project
builds or tests.

### Bazel output root

Use Bazel's platform default output root unless the local filesystem requires
a different location. Do not commit a machine-specific output path.

Set a local output root in `user.bazelrc` when necessary. This file is ignored
by Git. Use an absolute path so Bazel commands from workspace subdirectories
use the same location.

```bazelrc
startup --output_user_root=/path/to/local/bazel-cache
```

The tracked `.bazelrc` imports `user.bazelrc` automatically. Do not add the
startup option to each command. Do not share this output root with other
projects.

Examples:

```bash
bazel build //...
bazel test //...
bazel shutdown
```

Do not delete or expunge a shared local cache unless the user requests it.

## Testing layout

Full rules: **`docs/TESTING.md`**.

Short form:

| Kind | Location |
|------|----------|
| Unit | Co-located `test` blocks next to engines and applets |
| Goldens | `data/goldens/` |

Production `zig_library` targets must **not** depend on test-only packages.

## Common operations

### Add a worktree

```bash
cd utilz.git
git worktree add ../utilz-<name> <branch>

# Or create a new branch at the same time:
git worktree add ../utilz-<name> -b <new-branch> <start-point>
```

Feature branches start at `develop`. Hotfix branches start at `master`.

### List worktrees

```bash
cd utilz.git
git worktree list
```

### Remove a worktree

```bash
cd utilz.git
git worktree remove ../utilz-<name>
```

### Fetch and pull

```bash
cd utilz.git
git fetch --all
```

Then pull inside a specific worktree:

```bash
cd ../utilz-master
git pull
```

### Prune stale worktree references

If a worktree directory was deleted by hand:

```bash
cd utilz.git
git worktree prune
```

## Branch naming schema

Branches follow a tiered promotion model. Code flows **upward** through each
tier by merge. Never skip a tier.

```
master                    production: tagged releases only
  ↑ merge
develop                   integration: completed feature work lands here first
  ↑ merge
feature/*                 feature work
hotfix/*                  urgent production fixes (from master; merge to master AND develop)
```

### Branch prefixes

| Prefix | Branches from | Merges into | Purpose |
|---|---|---|---|
| `feature/<name>` | `develop` | `develop` | Feature work |
| `hotfix/<name>` | `master` | `master` + `develop` | Urgent production fixes |
| `develop` | — | `master` | Integration branch |
| `master` | — | — | Production |

Use lowercase kebab-case.

```
feature/sys-impl-attach
feature/echo-cat
hotfix/errno-table
```

### Release tag names

Every release tag must have a human codename. Use an Ubuntu-style
alphabetized pair: `{funny adjective} {animal name}`.

The adjective and the animal must start with the same letter. Advance
alphabetically across releases. You may reuse Ubuntu animal names. Do not
reuse Ubuntu adjectives.

Never choose or apply the tag name alone. First propose a small set of
candidate names. Then wait for the user to select one.

## Concurrent work

- Parallel tasks must own disjoint files.
- Run changes to shared files sequentially.
- Use isolated worktrees for concurrent write tasks.
- Never let two writers share a dirty worktree.

### Git operations

- **Subagents / worker agents must not run git.** No `git add`, `commit`,
  `checkout`, `restore`, `reset`, `switch`, `merge`, `rebase`, `push`,
  `pull`, `clean`, or `worktree` from a worker.
- Only the **orchestrator** (main agent, with the human’s request) may run
  git, and only for the requested operation.
- Workers that “clean up” with `git restore` / `git checkout --` destroy
  other agents’ uncommitted work. That is forbidden.

## Progressive merging workflow

### Feature work to production

```bash
cd utilz.git
git worktree add ../utilz-my-feature -b feature/my-feature develop

cd ../utilz-my-feature
# commit, iterate, run Bazel checks

cd ../utilz-develop
git merge feature/my-feature

cd ../utilz.git
git worktree remove ../utilz-my-feature
git branch -d feature/my-feature

cd ../utilz-master
git merge develop
git tag -a v1.2.0 -m "Release 1.2.0"
```

### Hotfix workflow

Hotfixes branch from master. Merge them into **master** and **develop**.

```bash
cd utilz.git
git worktree add ../utilz-hotfix-xyz -b hotfix/xyz master

cd ../utilz-hotfix-xyz
# fix, commit, run Bazel checks

cd ../utilz-master
git merge hotfix/xyz
git tag -a v1.1.1 -m "Hotfix 1.1.1"

cd ../utilz-develop
git merge hotfix/xyz

cd ../utilz.git
git worktree remove ../utilz-hotfix-xyz
git branch -d hotfix/xyz
```

### Merge direction rules

- Always merge upward: `feature → develop → master`.
- Never merge downward unless you complete a hotfix path.
- Never skip tiers. Do not merge a feature directly into master.
- Always merge from inside the **target** worktree. Change directory into
  the branch that receives the merge. Then run `git merge <source>`.
- Never merge from inside the bare repository. There is no working tree for
  conflict resolution.

## Rules for AI agents

- When the user names a branch, work inside the matching worktree.
- Do not run `git checkout` or `git switch` in a worktree to a branch that
  another worktree already has checked out. That command fails.
- If a worktree for the needed branch does not exist, create it with
  `git worktree add`.
- Run git metadata commands (`log`, `status`, `diff`, `fetch`) from the
  relevant worktree so context is correct.
- Follow the progressive merge order: feature → develop → master. Never skip
  tiers.
- Create new feature branches from `develop`, not from `master`.
- Always merge from inside the **target** worktree.
- After you merge a feature, remove its worktree and delete the branch.
- Keep the long-lived worktrees (`utilz-master`, `utilz-develop`) present.
- Always build and test with Bazel, rules_zig, and Zig 0.16. Honor the local
  `user.bazelrc` when it exists.
- Do not use system Zig for project verification.
- Do not treat markdown text as a substitute for failing Bazel checks.
- Do not add a shcore Bazel dependency to `//src:lib`.
- Name the applet backend `sys.Impl`.

## Writing style for new agent docs

Write new project procedure docs in **ASD-STE100** style when practical:

- Use short sentences.
- Use active voice.
- Use simple present tense for descriptions.
- Use imperative mood for procedures.
- Put one main idea in each sentence.
- Use the same technical term for the same thing every time.
- Prefer concrete steps over abstract policy essays.
