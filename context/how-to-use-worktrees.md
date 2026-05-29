# Working On SRS With Worktrees

## Purpose

SRS is a downstream monorepo. Its `rust/`, `cranelift/`, and `sld/` source
trees are ordinary tracked content. Cargo and Clippy are ordinary tracked
content under `rust/src/tools/cargo/` and `rust/src/tools/clippy/`.

Use one SRS worktree per task. A task worktree isolates its branch, source
edits, Rust bootstrap output, SRS build output, and Cargo home while keeping
all downstream changes in one reviewable SRS commit history.

The remaining git submodules are nested external dependencies such as LLVM,
documentation repositories, test suites, and linker fixtures. They are not
the downstream source trees where ordinary SRS changes should be committed.

## Create A Task Worktree

Use a unique branch, directory, and eventual rustup toolchain name per
concurrent task:

```bash
SRS=/Users/zanie/code/rust-toolchain/srs
WT=/Users/zanie/code/rust-toolchain/srs-<task-slug>
BRANCH=zb/<task-slug>
BASE=main

git -C "$SRS" worktree add -b "$BRANCH" "$WT" "$BASE"
git -C "$WT" submodule update --init --recursive
git -C "$WT" status --short --branch
```

If external dependency initialization is not needed for a narrow edit, it may
be deferred until the first build or test that needs those dependencies. Run
the recursive update before treating a missing nested dependency as a source
checkout problem.

Verify the ordinary downstream trees before editing:

```bash
test "$(git -C "$WT" rev-parse --show-toplevel)" = "$WT"
test -f "$WT/rust/x"
test -f "$WT/rust/src/tools/cargo/Cargo.toml"
test -f "$WT/rust/src/tools/clippy/Cargo.toml"
test -f "$WT/cranelift/Cargo.toml"
test -f "$WT/sld/Cargo.toml"
```

## Work In The Monorepo

Edit the task worktree directly:

```bash
cd "$WT"
$EDITOR rust/compiler/rustc_codegen_cranelift/src/lib.rs
$EDITOR rust/src/tools/cargo/src/cargo/core/compiler/mod.rs
$EDITOR cranelift/cranelift/codegen/src/lib.rs
$EDITOR sld/sld/src/main.rs
```

Use only the applicable paths. Cargo and Clippy are edited at their bootstrap
paths under `rust/src/tools/`; there is no SRS-level Cargo alias.

Keep builds rooted in the task worktree. Running SRS scripts from `$WT` places
SRS `target/` and `cargo-home/` there, while Rust bootstrap writes under
`$WT/rust/build/`:

```bash
cd "$WT"
./build.sh
NAME=srs-<task-slug>
./install.sh "$NAME"
rustc +"$NAME" -Vv
cargo +"$NAME" -Vv
```

On macOS, use `./with-sld.sh <command>` when a proof must explicitly select
the task's built linker. Use a task-specific `NAME`; concurrent agents must
not relink the same rustup toolchain name.

For a bounded Darwin linker smoke that does not need a new full toolchain, build
the task-local `sld` binary with an LLVM-backed toolchain, then use it to link
Cranelift-generated input:

```bash
cd "$WT"
SRS_TOOLCHAIN=stable SRS_SLD_TARGET_DIR="$WT/target/sld-stable" ./build-sld.sh
SRS_SLD_BIN="$WT/target/sld-stable/opt/sld" \
    ./with-sld.sh cargo +srs run --offline \
    --target-dir "$WT/target/smoke" \
    --manifest-path "$WT/target/fixtures/sld-smoke/Cargo.toml"
```

Do not assume unqualified `./build-sld.sh` is a usable linker-proof setup: by
default it builds `sld` with `+srs`, which is useful for backend coverage but
may fail if the current Cranelift toolchain cannot compile an intrinsic used
by the linker.

Put throwaway smoke crates and logs under ignored task-local output paths such
as `$WT/target/fixtures/` or an experiment-owned artifact directory. Do not
leave ad hoc untracked fixtures in the SRS source root.

Build success is setup evidence, not a behavioral result. Run and record the
relevant workload, test, or reproducer before claiming a toolchain change
works.

## Commit Downstream Changes

Stage only the files changed for the task, inspect the staged diff, and commit
once the relevant validation is complete:

```bash
git -C "$WT" status --short
git -C "$WT" add -- <changed-paths>
git -C "$WT" diff --cached --stat
git -C "$WT" diff --cached
git -C "$WT" commit
```

Changes under `rust/`, `rust/src/tools/cargo/`, `rust/src/tools/clippy/`,
`cranelift/`, and `sld/` are committed together in SRS as ordinary files.

## Pull Upstream Updates

Use the repository-owned import script for upstream updates:

```bash
cd "$WT"
git status --short
before="$(git rev-parse HEAD)"
./scripts/pull-upstream.sh rust
git log --oneline "$before"..HEAD
git diff --stat "$before"..HEAD
git diff "$before"..HEAD
```

Pass one of `rust`, `cargo`, `cranelift`, or `sld`, plus an optional upstream
ref. Start from a clean worktree: the script creates reviewable subtree import
and metadata commits. Inspect the full commit range, initialize any newly
introduced external dependency submodules, and run the relevant validation
before sharing the update:

```bash
git submodule update --init --recursive
```

## Share Work

A local SRS commit is sufficient for local builds. Never push a branch or open
a pull request unless the user explicitly asks for that public action. When the
user does ask to publish, inspect the configured SRS remote and push only the
SRS task branch:

```bash
git -C "$WT" remote -v
git -C "$WT" push -u origin "$BRANCH"
```

## Inspect Concurrent Work

The canonical SRS checkout provides one view of active task worktrees:

```bash
git -C "$SRS" worktree list
```

Before rebasing or replacing a shared base branch, use this list to find active
work. Never reuse another task's build output directory or rustup toolchain
name as a shortcut.

## Clean Up

First verify that intended changes and results have been committed or otherwise
preserved:

```bash
git -C "$WT" status --short --branch
```

Then remove the completed task worktree from the canonical checkout:

```bash
git -C "$SRS" worktree remove "$WT"
git -C "$SRS" worktree prune
```

Do not use force removal on a task worktree containing unpreserved changes or
results.
