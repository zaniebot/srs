#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${SRS_TMPDIR:-$HOME/code/tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp "$tmp_root/srs-gitmodules.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Cargo is tracked directly by SRS. A Rust subtree pull can restore the
# upstream gitlink declaration, which no longer describes this checkout.
if git config -f "$root/rust/.gitmodules" \
    --get-regexp '^submodule\.src/tools/cargo\.' >/dev/null 2>&1; then
    git config -f "$root/rust/.gitmodules" \
        --remove-section 'submodule.src/tools/cargo'
fi

write_component() {
    local prefix="$1"
    local modules="$2"

    [[ -f "$modules" ]] || return 0

    while read -r key _; do
        local name="${key#submodule.}"
        name="${name%.path}"

        local path
        path="$(git config -f "$modules" --get "submodule.$name.path")"

        local full_path="$prefix/$path"
        local mode
        mode="$(git -C "$root" ls-files --stage -- "$full_path" | awk 'NR == 1 { print $1 }')"
        [[ "$mode" == 160000 ]] || continue

        printf '[submodule "%s"]\n' "$full_path" >>"$tmp"
        printf '\tpath = %s\n' "$full_path" >>"$tmp"

        local field value
        for field in url branch shallow update; do
            if value="$(git config -f "$modules" --get "submodule.$name.$field")"; then
                printf '\t%s = %s\n' "$field" "$value" >>"$tmp"
            fi
        done
    done < <(git config -f "$modules" --get-regexp '^submodule\..*\.path$' || true)
}

write_component rust "$root/rust/.gitmodules"
write_component cranelift "$root/cranelift/.gitmodules"
write_component sld "$root/sld/.gitmodules"

if [[ -f "$root/.gitmodules" ]] && cmp -s "$tmp" "$root/.gitmodules"; then
    exit 0
fi

mv "$tmp" "$root/.gitmodules"
