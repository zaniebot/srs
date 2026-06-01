#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${1:-srs}"
rust_dir="${SRS_RUST_DIR:-$root/rust}"
toolchain_dir="${2:-}"
cargo_bin="${3:-}"
sld_bin="${SRS_SLD_BIN:-$root/target/sld/opt/sld}"
install_root="${SRS_INSTALL_ROOT:-$HOME/code/tmp/srs-toolchains}"
snapshot_dir="$install_root/$name"
rustup_bin="${SRS_RUSTUP_BIN:-rustup}"
replace="${SRS_INSTALL_REPLACE:-0}"

if [[ -z "$name" || "$name" == -* || "$name" == */* || "$name" == *\\* || "$name" == "." || "$name" == ".." ]]; then
    printf 'invalid SRS toolchain name %s: use a single path component\n' "$name" >&2
    exit 2
fi

if [[ "$replace" != "0" && "$replace" != "1" ]]; then
    printf 'SRS_INSTALL_REPLACE must be 0 or 1, got %s\n' "$replace" >&2
    exit 2
fi

if [[ -e "$snapshot_dir" || -L "$snapshot_dir" ]] && [[ "$replace" != "1" ]]; then
    printf 'SRS toolchain snapshot already exists at %s; set SRS_INSTALL_REPLACE=1 to replace it\n' "$snapshot_dir" >&2
    exit 2
fi

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

missing_toolchain_bins=()
for bin in cargo-clippy clippy-driver; do
    if [[ ! -x "$toolchain_dir/bin/$bin" ]]; then
        missing_toolchain_bins+=("$bin")
    fi
done

if [[ "${#missing_toolchain_bins[@]}" -ne 0 ]]; then
    printf 'incomplete stage2 toolchain at %s: missing executable(s): %s\n' \
        "$toolchain_dir" "${missing_toolchain_bins[*]}" >&2
    exit 2
fi

if [[ ! -x "$sld_bin" ]]; then
    printf 'missing sld binary at %s; run %s/build-sld.sh first\n' "$sld_bin" "$root" >&2
    exit 2
fi

mkdir -p "$install_root"
staging_dir="$(mktemp -d "$install_root/.${name}.tmp.XXXXXX")"
staging_dir_physical="$(cd -P "$staging_dir" && pwd)"
replaced_snapshot=""
snapshot_published=0
install_complete=0
cleanup() {
    if [[ -n "${staging_dir:-}" ]] && [[ -e "$staging_dir" || -L "$staging_dir" ]]; then
        rm -rf "$staging_dir"
    fi
    if [[ "$install_complete" == "1" ]]; then
        if [[ -n "$replaced_snapshot" ]] && [[ -e "$replaced_snapshot" || -L "$replaced_snapshot" ]]; then
            rm -rf "$replaced_snapshot"
        fi
        return
    fi
    if [[ "$snapshot_published" == "1" ]] && [[ -e "$snapshot_dir" || -L "$snapshot_dir" ]]; then
        rm -rf "$snapshot_dir"
    fi
    if [[ -n "$replaced_snapshot" ]] && [[ -e "$replaced_snapshot" || -L "$replaced_snapshot" ]]; then
        mv "$replaced_snapshot" "$snapshot_dir"
    fi
}
trap cleanup EXIT

# Prefer copy-on-write filesystem clones where the host supports them. The
# portable fallback keeps installed names independent from mutable build
# outputs even when clones are unavailable.
if [[ "$(uname -s)" == "Darwin" ]]; then
    cp -cR "$toolchain_dir/." "$staging_dir" 2>/dev/null || cp -pR "$toolchain_dir/." "$staging_dir"
elif [[ "$(uname -s)" == "Linux" ]]; then
    cp --reflink=auto -a "$toolchain_dir/." "$staging_dir" 2>/dev/null || cp -pR "$toolchain_dir/." "$staging_dir"
else
    cp -pR "$toolchain_dir/." "$staging_dir"
fi

# Bootstrap stage 2 sysroots link rust-src back into the mutable checkout.
# Omit those optional sources instead of publishing a snapshot that stops
# being self-contained when its source worktree is removed.
rm -f "$staging_dir/lib/rustlib/rustc-src/rust" "$staging_dir/lib/rustlib/src/rust"

# A Rust bootstrap sysroot does not include Cargo by default. Keep copied Cargo
# and linker binaries next to a copied SRS wrapper so the snapshot survives
# later rebuilds and source-worktree cleanup.
rm -f "$staging_dir/bin/cargo-srs-real" "$staging_dir/bin/cargo"
install -m 755 "$cargo_bin" "$staging_dir/bin/cargo-srs-real"
install -m 755 "$root/cargo-srs.sh" "$staging_dir/bin/cargo"

# Rustc prepends this per-target tools directory to PATH before spawning the
# configured linker. Keep the baked-in default linker name relocatable.
host="$("$staging_dir/bin/rustc" --print host-tuple)"
tools_bin="$staging_dir/lib/rustlib/$host/bin"
mkdir -p "$tools_bin"
rm -f "$tools_bin/sld"
install -m 755 "$sld_bin" "$tools_bin/sld"

external_symlink_found=0
while IFS= read -r -d '' symlink; do
    target="$(readlink "$symlink")"
    if [[ "$target" == /* ]]; then
        printf 'refusing absolute symlink in SRS toolchain snapshot: %s -> %s\n' "$symlink" "$target" >&2
        external_symlink_found=1
        continue
    fi
    symlink_dir="$(cd -P "$(dirname "$symlink")" && pwd)"
    if ! target_parent="$(cd -P "$symlink_dir/$(dirname "$target")" && pwd)"; then
        printf 'refusing unresolved symlink in SRS toolchain snapshot: %s -> %s\n' "$symlink" "$target" >&2
        external_symlink_found=1
        continue
    fi
    target_name="$(basename "$target")"
    if [[ "$target_name" == "." || "$target_name" == ".." ]]; then
        resolved_target="$(cd -P "$target_parent/$target_name" && pwd)"
    else
        resolved_target="$target_parent/$target_name"
    fi
    if [[ "$resolved_target" != "$staging_dir_physical" && "$resolved_target" != "$staging_dir_physical/"* ]]; then
        printf 'refusing external relative symlink in SRS toolchain snapshot: %s -> %s\n' "$symlink" "$target" >&2
        external_symlink_found=1
    fi
done < <(find "$staging_dir" -type l -print0)
if [[ "$external_symlink_found" == "1" ]]; then
    exit 2
fi

if [[ -e "$snapshot_dir" || -L "$snapshot_dir" ]]; then
    if [[ "$replace" != "1" ]]; then
        printf 'SRS toolchain snapshot already exists at %s; set SRS_INSTALL_REPLACE=1 to replace it\n' "$snapshot_dir" >&2
        exit 2
    fi
    replaced_snapshot="$snapshot_dir.replaced.$$"
    mv "$snapshot_dir" "$replaced_snapshot"
fi

mv "$staging_dir" "$snapshot_dir"
staging_dir=""
snapshot_published=1

if ! "$rustup_bin" toolchain link "$name" "$snapshot_dir"; then
    exit 1
fi

install_complete=1

printf 'linked rustup toolchain %s -> %s\n' "$name" "$snapshot_dir"
printf 'installed copied Cargo wrapper at %s\n' "$snapshot_dir/bin/cargo"
printf 'installed copied sld linker at %s\n' "$snapshot_dir/lib/rustlib/$host/bin/sld"
