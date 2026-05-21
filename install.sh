#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${1:-srs}"
rust_dir="${SRS_RUST_DIR:-$root/repos/rust}"
toolchain_dir="${2:-}"
cargo_bin="${3:-}"

if [[ -z "$toolchain_dir" ]]; then
    host_stage2="$rust_dir/build/host/stage2"
    if [[ -x "$host_stage2/bin/rustc" ]]; then
        toolchain_dir="$host_stage2"
    else
        shopt -s nullglob
        stage2_dirs=("$rust_dir"/build/*/stage2)
        shopt -u nullglob

        if [[ "${#stage2_dirs[@]}" -ne 1 ]]; then
            printf 'expected exactly one stage2 toolchain under %s/build; pass the toolchain path explicitly\n' "$rust_dir" >&2
            exit 2
        fi

        toolchain_dir="${stage2_dirs[0]}"
    fi
fi

if [[ ! -x "$toolchain_dir/bin/rustc" ]]; then
    printf 'missing rustc in toolchain directory %s\n' "$toolchain_dir" >&2
    exit 2
fi

if [[ -z "$cargo_bin" ]]; then
    host_cargo="$rust_dir/build/host/stage2-tools-bin/cargo"
    if [[ -x "$host_cargo" ]]; then
        cargo_bin="$host_cargo"
    else
        shopt -s nullglob
        cargo_bins=("$rust_dir"/build/*/stage2-tools-bin/cargo)
        shopt -u nullglob

        if [[ "${#cargo_bins[@]}" -ne 1 ]]; then
            printf 'expected exactly one stage2 Cargo under %s/build; pass the Cargo path explicitly\n' "$rust_dir" >&2
            exit 2
        fi

        cargo_bin="${cargo_bins[0]}"
    fi
fi

if [[ ! -x "$cargo_bin" ]]; then
    printf 'missing built Cargo at %s\n' "$cargo_bin" >&2
    exit 2
fi

# A linked Rust bootstrap sysroot does not include Cargo by default.
ln -sf "$cargo_bin" "$toolchain_dir/bin/cargo"
rustup toolchain link "$name" "$toolchain_dir"
printf 'linked rustup toolchain %s -> %s\n' "$name" "$toolchain_dir"
