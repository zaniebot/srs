# Working On SRS With Worktrees

## Purpose

SRS is an integration repository: its gitlinks record the exact Rust, nested
Cargo, Cranelift, and `sld` revisions that form a toolchain. Concurrent work
should therefore have two kinds of isolation:

- one SRS superproject worktree for the integration branch and its build
  outputs;
- one linked worktree for each component repository used by that task.

Use the materialized repositories in the canonical SRS checkout as object
stores and branch coordinators. Do not routinely initialize independent
submodule repositories inside every task worktree. Linked component worktrees
share the existing object databases, show up in `git worktree list`, prevent
two agents from checking out the same component branch concurrently, still
appear to SRS as normal gitlink checkouts, and can be removed cleanly when the
task is finished.

## Important Trap

A new SRS worktree initially contains uninitialized gitlink paths. Before a
component is materialized, this command does **not** inspect Cranelift:

```bash
git -C "$WT/repos/cranelift" status
```

Git walks upward and reports the SRS superproject instead. A leading `-` in
`git submodule status` is a warning that the submodule is not registered or
materialized. A directly linked component worktree must also be registered
with `git submodule init` so status is informative. Do not branch, edit,
build, or commit in a component path until its `--show-toplevel` check resolves
to that component path.

## Bootstrap The Store

Designate one clean checkout as the persistent object store:

```bash
SRS=/Users/zanie/code/rust-toolchain/srs

git -C "$SRS" status --short --branch
git -C "$SRS" submodule init repos/rust repos/cranelift repos/sld
git -C "$SRS" submodule status repos/rust repos/cranelift repos/sld
```

`git submodule init` registers URLs but does not checkout source or replace
edits. If each component's `git rev-parse --show-toplevel` resolves to its
component path, inspect the existing checkout before changing it:

```bash
git -C "$SRS/repos/rust" status --short --branch
git -C "$SRS/repos/cranelift" status --short --branch
git -C "$SRS/repos/sld" status --short --branch
git -C "$SRS/repos/rust" submodule init src/tools/cargo
git -C "$SRS/repos/rust" submodule status src/tools/cargo
```

Once nested Cargo is materialized at its own path, inspect it with
`git -C "$SRS/repos/rust/src/tools/cargo" status --short --branch` as well.

If a component's `--show-toplevel` instead resolves to SRS itself, that
component is not materialized. Only if its empty path is intentionally safe to
populate, materialize the pinned repositories once in the canonical checkout:

```bash
git -C "$SRS" submodule update --init repos/rust repos/cranelift repos/sld
git -C "$SRS/repos/rust" submodule update --init src/tools/cargo
```

Do not run these update commands over unrelated local component edits. Make a
separate store checkout instead if the canonical component trees are in use.

## Create A Task Worktree

Use a unique SRS branch, directory, and eventual rustup toolchain name per
concurrent task:

```bash
SRS=/Users/zanie/code/rust-toolchain/srs
WT=/Users/zanie/code/rust-toolchain/srs-<task-slug>
BRANCH=zb/<task-slug>
BASE=main

git -C "$SRS" worktree add -b "$BRANCH" "$WT" "$BASE"
git -C "$WT" submodule init repos/rust repos/cranelift repos/sld

rust_sha="$(git -C "$WT" rev-parse HEAD:repos/rust)"
cranelift_sha="$(git -C "$WT" rev-parse HEAD:repos/cranelift)"
sld_sha="$(git -C "$WT" rev-parse HEAD:repos/sld)"

git -C "$SRS/repos/rust" worktree add --detach "$WT/repos/rust" "$rust_sha"
git -C "$SRS/repos/cranelift" worktree add --detach "$WT/repos/cranelift" "$cranelift_sha"
git -C "$SRS/repos/sld" worktree add --detach "$WT/repos/sld" "$sld_sha"

git -C "$WT/repos/rust" submodule init src/tools/cargo
cargo_sha="$(git -C "$WT/repos/rust" rev-parse HEAD:src/tools/cargo)"
git -C "$SRS/repos/rust/src/tools/cargo" worktree add --detach \
    "$WT/repos/rust/src/tools/cargo" "$cargo_sha"
```

If `git worktree add` says the component object store does not contain a
pinned commit, fetch that component in the canonical store or initialize a
fresh store first. Do not silently substitute a nearby component revision.

Verify the completed layout before doing any work:

```bash
test "$(git -C "$WT/repos/rust" rev-parse --show-toplevel)" = "$WT/repos/rust"
test "$(git -C "$WT/repos/cranelift" rev-parse --show-toplevel)" = "$WT/repos/cranelift"
test "$(git -C "$WT/repos/sld" rev-parse --show-toplevel)" = "$WT/repos/sld"
test "$(git -C "$WT/repos/rust/src/tools/cargo" rev-parse --show-toplevel)" = \
    "$WT/repos/rust/src/tools/cargo"

git -C "$WT" submodule status repos/rust repos/cranelift repos/sld
git -C "$WT/repos/rust" submodule status src/tools/cargo
```

The four status lines must not start with `-`. Before edits, the top-level
three SHAs should match the SRS gitlinks exactly.

## Work In Components

Leave an untouched component detached at its SRS pin. Create branches only in
the repositories that the task changes:

```bash
git -C "$WT/repos/cranelift" switch -c "$BRANCH"
git -C "$WT/repos/sld" switch -c "$BRANCH"
git -C "$WT/repos/rust" switch -c "$BRANCH"
git -C "$WT/repos/rust/src/tools/cargo" switch -c "$BRANCH"
```

Use only the applicable lines. The same branch label may be used across these
separate repositories, but a distinct task must use a distinct label.

Keep builds rooted in the task worktree. Running SRS scripts from `$WT` places
SRS `target/` and `cargo-home/` there, while Rust bootstrap writes under
`$WT/repos/rust/build/`:

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
default it builds `sld` with `+srs`, which is itself useful for backend
coverage but may fail if the current Cranelift toolchain cannot compile an
intrinsic used by the linker.

Put throwaway smoke crates and logs under ignored task-local output paths such
as `$WT/target/fixtures/` or an experiment-owned artifact directory. Do not
leave ad hoc untracked fixtures in the SRS source root.

Build success is setup evidence, not a behavioral result. Run and record the
relevant workload, test, or reproducer before claiming a toolchain change
works.

## Commit The Stack

Commit leaf repositories first, then commit the gitlinks that consume them.
For a task touching every layer, the dependency order is:

```bash
git -C "$WT/repos/rust/src/tools/cargo" commit
git -C "$WT/repos/rust" add src/tools/cargo
git -C "$WT/repos/rust" commit

git -C "$WT/repos/cranelift" commit
git -C "$WT/repos/sld" commit

git -C "$WT" add repos/rust repos/cranelift repos/sld
git -C "$WT" diff --cached --submodule=short
git -C "$WT" commit
```

Skip untouched repositories and stage only the pins the task changed. The SRS
commit is the integration record; it should not point at uncommitted component
work.

## Share The Stack

Local linked-worktree commits are sufficient for local builds, but another
machine cannot check out an SRS pin until its referenced component commit is
available from that component's configured remote. If the user explicitly asks
to publish a task, first verify that `origin` is the intended remote for each
repository, then push in dependency order:

```bash
git -C "$WT/repos/rust/src/tools/cargo" push -u origin "$BRANCH"
git -C "$WT/repos/rust" push -u origin "$BRANCH"
git -C "$WT/repos/cranelift" push -u origin "$BRANCH"
git -C "$WT/repos/sld" push -u origin "$BRANCH"
git -C "$WT" push -u origin "$BRANCH"
```

The Rust push must come after Cargo if Rust advances the nested Cargo gitlink.
The SRS push must come last after every changed component pin is remotely
reachable. Never push or open pull requests unless the user asks for that
public action.

## Inspect Concurrent Work

The canonical stores provide a single view of component worktrees:

```bash
git -C "$SRS" worktree list
git -C "$SRS/repos/rust" worktree list
git -C "$SRS/repos/rust/src/tools/cargo" worktree list
git -C "$SRS/repos/cranelift" worktree list
git -C "$SRS/repos/sld" worktree list
```

Before rebasing or replacing a shared base branch, use these lists to find
active work. Never reuse another task's build output directory or rustup
toolchain name as a shortcut.

## Clean Up

First verify that intended changes have been committed or otherwise preserved:

```bash
git -C "$WT" status --short --branch
git -C "$WT/repos/rust" status --short --branch
git -C "$WT/repos/rust/src/tools/cargo" status --short --branch
git -C "$WT/repos/cranelift" status --short --branch
git -C "$WT/repos/sld" status --short --branch
```

Remove a completed task from the leaves upward:

```bash
git -C "$SRS/repos/rust/src/tools/cargo" worktree remove "$WT/repos/rust/src/tools/cargo"
mkdir -p "$WT/repos/rust/src/tools/cargo"
git -C "$SRS/repos/rust" worktree remove "$WT/repos/rust"
git -C "$SRS/repos/cranelift" worktree remove "$WT/repos/cranelift"
git -C "$SRS/repos/sld" worktree remove "$WT/repos/sld"
mkdir -p "$WT/repos/rust" "$WT/repos/cranelift" "$WT/repos/sld"
git -C "$SRS" worktree remove "$WT"
```

The empty `mkdir` placeholders keep the parent gitlink worktree clean after
its child worktree is removed. Do not use force removal on a task worktree
containing unpreserved results.

## Workflow Proof

This layout was exercised from a disposable SRS worktree on macOS:

- A new superproject worktree reported all top-level gitlinks with a leading
  `-`, and `git -C repos/cranelift rev-parse --show-toplevel` resolved to the
  superproject, confirming the initialization trap.
- After registering the gitlinks with `git submodule init`, linked worktrees
  for pinned `repos/rust`, nested `src/tools/cargo`, `repos/cranelift`, and
  `repos/sld` all resolved to their own paths and made `git submodule status`
  report initialized pins.
- The populated task checkout occupied about `504M`; it did not inherit the
  canonical Rust checkout's existing `26G` `build/` directory.
- A disposable commit made only in the task's Cranelift worktree appeared as a
  stageable `repos/cranelift` gitlink change in SRS, while the canonical
  Cranelift worktree stayed at its original pin.
- A comparison worktree initialized through `git submodule update` remained
  ineligible for ordinary `git worktree remove` even after its component was
  deinitialized; Git required forced removal. The linked-component layout was
  removed cleanly after recreating empty gitlink placeholders.
- In a subagent-owned edit-path smoke, committed disposable markers in nested
  Cargo, Cranelift, and `sld` promoted cleanly through a Rust gitlink commit
  and then an SRS gitlink commit. The canonical component stores remained
  clean at their original revisions throughout.
- In a subagent-owned experiment `226` smoke, unqualified `./build-sld.sh`
  produced an `sld` linked with `+srs` that failed while linking a tiny Darwin
  executable because Cranelift reported unsupported
  `llvm.aarch64.crypto.sha256h`. Rebuilding only `sld` with
  `SRS_TOOLCHAIN=stable` and linking an ignored-path `cargo +srs` smoke
  succeeded with runtime output `sld-smoke-guided-ok:10`.

This proves the isolation and gitlink-promotion workflow. Each actual compiler,
backend, or linker change still needs its own build and workload-level proof.
