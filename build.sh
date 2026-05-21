#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rust_dir="${SRS_RUST_DIR:-$root/repos/rust}"

if [[ ! -x "$rust_dir/x" ]]; then
    printf 'missing Rust checkout at %s\n' "$rust_dir" >&2
    exit 2
fi

cd "$rust_dir"
exec ./x build \
    --config "$root/bootstrap.toml" \
    --stage 2 \
    compiler/rustc \
    rustc_codegen_cranelift \
    library/std \
    src/tools/cargo
