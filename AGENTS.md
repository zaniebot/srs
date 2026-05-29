# SRS Agent Instructions

SRS is a downstream monorepo. The top-level `rust/`, `cranelift/`, and `sld/`
trees are ordinary tracked content, as are Cargo and Clippy under
`rust/src/tools/`. Commit downstream changes in SRS itself.

For concurrent development, create one SRS worktree per task and read
[`context/how-to-use-worktrees.md`](context/how-to-use-worktrees.md) first.

Refresh imported upstream content with
`scripts/pull-upstream.sh {rust|cargo|cranelift|sld} [ref]`, review the
resulting commits, and validate them before sharing. Initialize the remaining
nested external dependencies with:

```bash
git submodule update --init --recursive
```

Never push branches, open pull requests, or comment on public forums unless the
user explicitly asks for that public action. Do not reply to Slack or GitHub
threads on the user's behalf.
