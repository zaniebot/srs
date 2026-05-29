#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rust_sha="${1:-}"

if [[ -z "$rust_sha" ]]; then
    printf 'usage: %s rust-upstream-sha\n' "$0" >&2
    exit 2
fi

rust_sha="$(git -C "$root" rev-parse "$rust_sha^{commit}")"
short_sha="$(git -C "$root" rev-parse --short=9 "$rust_sha")"
commit_date="$(git -C "$root" show -s --format=%cs "$rust_sha")"

bors_email='bors@rust-lang\.org'
temporary_bors_email='122020455+rust-bors\[bot\]@users\.noreply\.github\.com'
latest_upstream="$(
    git -C "$root" rev-list \
        --author-date-order \
        --author="$bors_email" \
        --author="$temporary_bors_email" \
        -n1 \
        "$rust_sha"
)"

if [[ -z "$latest_upstream" ]]; then
    printf 'could not find an upstream Rust merge commit reachable from %s\n' "$rust_sha" >&2
    exit 2
fi

ci_llvm_commit="$(
    git -C "$root" rev-list \
        --first-parent \
        -n1 \
        "$latest_upstream" \
        --author="$bors_email" \
        --author="$temporary_bors_email" \
        -- \
        src/llvm-project \
        src/bootstrap/download-ci-llvm-stamp \
        src/version
)"

if [[ -z "$ci_llvm_commit" ]]; then
    printf 'could not find a CI LLVM commit reachable from %s\n' "$latest_upstream" >&2
    exit 2
fi

printf '%s\n%s\n%s\n' "$rust_sha" "$short_sha" "$commit_date" >"$root/rust/git-commit-info"
printf '%s\n' "$ci_llvm_commit" >"$root/rust/ci-llvm-commit"
