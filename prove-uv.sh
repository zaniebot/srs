#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
uv_dir="${1:-$root/../uv}"
toolchain="${SRS_TOOLCHAIN:-srs}"
target_dir="${SRS_UV_TARGET_DIR:-$root/target/uv-cranelift}"
cargo_home="${SRS_CARGO_HOME:-$root/cargo-home}"

if [[ ! -f "$uv_dir/Cargo.toml" ]]; then
    printf 'missing uv Cargo.toml at %s\n' "$uv_dir" >&2
    exit 2
fi

mkdir -p "$target_dir" "$cargo_home"
cd "$uv_dir"

exec env \
    CARGO_HOME="$cargo_home" \
    CARGO_TARGET_DIR="$target_dir" \
    CARGO_PROFILE_DEV_CODEGEN_BACKEND=cranelift \
    cargo +"$toolchain" build -Zcodegen-backend --locked -p uv
