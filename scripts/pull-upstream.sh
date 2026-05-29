#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
component="${1:-}"
requested_ref="${2:-}"

if [[ -z "$component" ]]; then
    printf 'usage: %s {rust|cargo|cranelift|sld} [ref]\n' "$0" >&2
    exit 2
fi

if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    printf 'SRS worktree must be clean before pulling an upstream subtree\n' >&2
    exit 2
fi

case "$component" in
    rust)
        prefix=rust
        upstream_url="${SRS_RUST_UPSTREAM_URL:-https://github.com/rust-lang/rust.git}"
        upstream_ref="${requested_ref:-main}"
        ;;
    cargo)
        prefix=rust/src/tools/cargo
        upstream_url="${SRS_CARGO_UPSTREAM_URL:-https://github.com/rust-lang/cargo.git}"
        upstream_ref="${requested_ref:-master}"
        ;;
    cranelift)
        prefix=cranelift
        upstream_url="${SRS_CRANELIFT_UPSTREAM_URL:-https://github.com/bytecodealliance/wasmtime.git}"
        upstream_ref="${requested_ref:-main}"
        ;;
    sld)
        prefix=sld
        upstream_url="${SRS_SLD_UPSTREAM_URL:-https://github.com/zanieb/sld.git}"
        upstream_ref="${requested_ref:-main}"
        ;;
    *)
        printf 'unknown component: %s\n' "$component" >&2
        exit 2
        ;;
esac

pull_subtree() {
    git -C "$root" subtree pull \
        --prefix="$prefix" \
        "$upstream_url" \
        "$upstream_ref" \
        --squash
}

resolve_materialized_cargo_conflict() {
    local unmerged
    unmerged="$(git -C "$root" ls-files -u | awk '{ print $4 }' | sort -u)"

    if [[ -z "$unmerged" ]]; then
        printf 'Rust subtree pull failed without the expected Cargo conflict\n' >&2
        return 1
    fi

    local path
    while IFS= read -r path; do
        case "$path" in
            rust/src/tools/cargo~*) ;;
            *)
                printf 'unexpected Rust subtree conflict path: %s\n' "$path" >&2
                return 1
                ;;
        esac
    done <<<"$unmerged"

    while IFS= read -r path; do
        git -C "$root" rm -f --cached -- "$path"
        rmdir "$root/$path" 2>/dev/null || true
    done <<<"$unmerged"

    git -C "$root" commit -m 'Merge Rust subtree while preserving materialized Cargo'
}

if ! pull_subtree; then
    if [[ "$component" != rust ]]; then
        printf '%s subtree pull failed; inspect the worktree\n' "$component" >&2
        exit 1
    fi
    resolve_materialized_cargo_conflict
fi

upstream_sha="$(git -C "$root" rev-parse FETCH_HEAD)"
if [[ "$component" == rust ]]; then
    "$root/scripts/update-rust-snapshot-metadata.sh" "$upstream_sha"
fi
"$root/scripts/refresh-submodule-metadata.sh"

metadata_paths=(.gitmodules rust/.gitmodules)
if [[ "$component" == rust ]]; then
    metadata_paths+=(rust/git-commit-info rust/ci-llvm-commit)
fi

if ! git -C "$root" diff --quiet -- "${metadata_paths[@]}"; then
    git -C "$root" add -- "${metadata_paths[@]}"
    git -C "$root" commit -m "Refresh metadata after pulling $component"
fi
