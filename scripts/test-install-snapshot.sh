#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_root="${SRS_TEST_TMPDIR:-$HOME/code/tmp}"
mkdir -p "$scratch_root"
scratch="$(mktemp -d "$scratch_root/srs-install-snapshot.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

toolchain_dir="$scratch/stage2"
cargo_bin="$scratch/cargo"
sld_bin="$scratch/sld"
rustup_bin="$scratch/rustup"
rustup_links="$scratch/rustup-links"
install_root="$scratch/install-root"
name="srs-snapshot-smoke"
snapshot_dir="$install_root/$name"
host="fake-host"

mkdir -p \
    "$toolchain_dir/bin" \
    "$toolchain_dir/lib/rustlib/rustc-src" \
    "$toolchain_dir/lib/rustlib/src" \
    "$rustup_links" \
    "$scratch/rust-source"
ln -s "$scratch/rust-source" "$toolchain_dir/lib/rustlib/rustc-src/rust"
ln -s "$scratch/rust-source" "$toolchain_dir/lib/rustlib/src/rust"

cat > "$toolchain_dir/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--print" && "${2:-}" == "host-tuple" ]]; then
    printf 'fake-host\n'
    exit 0
fi
printf 'fake rustc A\n'
EOF
chmod +x "$toolchain_dir/bin/rustc"

cat > "$cargo_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake cargo A\n'
EOF
chmod +x "$cargo_bin"

cat > "$sld_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake sld A\n'
EOF
chmod +x "$sld_bin"

cat > "$rustup_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -ne 4 || "$1" != "toolchain" || "$2" != "link" ]]; then
    printf 'unexpected fake rustup invocation\n' >&2
    exit 2
fi
if [[ "${SRS_TEST_RUSTUP_FAIL:-0}" == "1" ]]; then
    printf 'requested fake rustup failure\n' >&2
    exit 1
fi
ln -sfn "$4" "$SRS_TEST_RUSTUP_LINKS/$3"
EOF
chmod +x "$rustup_bin"

install_snapshot() {
    env \
        SRS_INSTALL_ROOT="$install_root" \
        SRS_INSTALL_REPLACE="${SRS_INSTALL_REPLACE:-0}" \
        SRS_RUSTUP_BIN="$rustup_bin" \
        SRS_SLD_BIN="$sld_bin" \
        SRS_TEST_RUSTUP_FAIL="${SRS_TEST_RUSTUP_FAIL:-0}" \
        SRS_TEST_RUSTUP_LINKS="$rustup_links" \
        "$root/install.sh" "$name" "$toolchain_dir" "$cargo_bin"
}

install_snapshot

if [[ "$(readlink "$rustup_links/$name")" != "$snapshot_dir" ]]; then
    printf 'fake rustup link did not point at installed snapshot\n' >&2
    exit 1
fi

for copied_path in \
    "$snapshot_dir/bin/cargo" \
    "$snapshot_dir/bin/cargo-srs-real" \
    "$snapshot_dir/lib/rustlib/$host/bin/sld"
do
    if [[ -L "$copied_path" ]]; then
        printf 'installed attachment remained a symlink: %s\n' "$copied_path" >&2
        exit 1
    fi
done

for omitted_path in \
    "$snapshot_dir/lib/rustlib/rustc-src/rust" \
    "$snapshot_dir/lib/rustlib/src/rust"
do
    if [[ -e "$omitted_path" || -L "$omitted_path" ]]; then
        printf 'installed snapshot retained mutable rust-src symlink: %s\n' "$omitted_path" >&2
        exit 1
    fi
done

before="$(cksum \
    "$snapshot_dir/bin/rustc" \
    "$snapshot_dir/bin/cargo" \
    "$snapshot_dir/bin/cargo-srs-real" \
    "$snapshot_dir/lib/rustlib/$host/bin/sld")"

rm -rf "$toolchain_dir"
rm -f "$cargo_bin" "$sld_bin"

if [[ "$("$snapshot_dir/bin/rustc")" != "fake rustc A" ]]; then
    printf 'installed rustc stopped working after source cleanup\n' >&2
    exit 1
fi
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installed Cargo stopped working after source cleanup\n' >&2
    exit 1
fi
if [[ "$("$snapshot_dir/lib/rustlib/$host/bin/sld")" != "fake sld A" ]]; then
    printf 'installed sld stopped working after source cleanup\n' >&2
    exit 1
fi

after="$(cksum \
    "$snapshot_dir/bin/rustc" \
    "$snapshot_dir/bin/cargo" \
    "$snapshot_dir/bin/cargo-srs-real" \
    "$snapshot_dir/lib/rustlib/$host/bin/sld")"
if [[ "$before" != "$after" ]]; then
    printf 'installed snapshot changed after source cleanup\n' >&2
    exit 1
fi

if install_snapshot > "$scratch/reinstall.log" 2>&1; then
    printf 'installer unexpectedly replaced an existing label without opt-in\n' >&2
    exit 1
fi
if ! grep -q 'SRS toolchain snapshot already exists' "$scratch/reinstall.log"; then
    printf 'installer did not explain the existing-label refusal\n' >&2
    exit 1
fi

mkdir -p "$toolchain_dir/bin" "$toolchain_dir/lib"
cat > "$toolchain_dir/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--print" && "${2:-}" == "host-tuple" ]]; then
    printf 'fake-host\n'
    exit 0
fi
printf 'fake rustc B\n'
EOF
chmod +x "$toolchain_dir/bin/rustc"

cat > "$cargo_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake cargo B\n'
EOF
chmod +x "$cargo_bin"

cat > "$sld_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake sld B\n'
EOF
chmod +x "$sld_bin"

if SRS_INSTALL_REPLACE=1 SRS_TEST_RUSTUP_FAIL=1 install_snapshot > "$scratch/replace-failure.log" 2>&1; then
    printf 'installer unexpectedly accepted requested fake rustup failure\n' >&2
    exit 1
fi
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installer did not roll back snapshot after rustup failure\n' >&2
    exit 1
fi

ln -s "$scratch/rust-source" "$toolchain_dir/lib/mutable-external"
if SRS_INSTALL_REPLACE=1 install_snapshot > "$scratch/external-symlink.log" 2>&1; then
    printf 'installer unexpectedly accepted a retained absolute symlink\n' >&2
    exit 1
fi
if ! grep -q 'refusing absolute symlink in SRS toolchain snapshot' "$scratch/external-symlink.log"; then
    printf 'installer did not explain the retained absolute symlink refusal\n' >&2
    exit 1
fi
rm "$toolchain_dir/lib/mutable-external"
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installer changed snapshot after rejecting an absolute symlink\n' >&2
    exit 1
fi

SRS_INSTALL_REPLACE=1 install_snapshot
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo B" ]]; then
    printf 'installer did not replace snapshot after explicit opt-in\n' >&2
    exit 1
fi

printf 'immutable install snapshot smoke passed\n'
