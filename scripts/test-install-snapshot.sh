#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_root="${SRS_TEST_TMPDIR:-$HOME/code/tmp}"
mkdir -p "$scratch_root"
scratch="$(mktemp -d "$scratch_root/srs-install-snapshot.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

toolchain_dir="$scratch/stage2"
cargo_bin="$scratch/cargo"
sld_bin="$scratch/sld"
rustup_bin="$scratch/rustup"
rustup_links="$scratch/rustup-links"
physical_install_root="$scratch/physical-install-root"
install_root="$scratch/install-root"
name="srs-snapshot-smoke"
snapshot_dir="$install_root/$name"
host="fake-host"

mkdir -p \
    "$toolchain_dir/bin" \
    "$toolchain_dir/lib/rustlib/rustc-src" \
    "$toolchain_dir/lib/rustlib/src" \
    "$rustup_links" \
    "$physical_install_root" \
    "$scratch/rust-source"
ln -s "$physical_install_root" "$install_root"
ln -s "$scratch/rust-source" "$toolchain_dir/lib/rustlib/rustc-src/rust"
ln -s "$scratch/rust-source" "$toolchain_dir/lib/rustlib/src/rust"

cat > "$toolchain_dir/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--print" && "${2:-}" == "host-tuple" ]]; then
    if [[ -n "${SRS_TEST_COLLIDE_BACKUP_BASE:-}" ]]; then
        mkdir -p "$SRS_TEST_COLLIDE_BACKUP_BASE.$PPID"
    fi
    if [[ -n "${SRS_TEST_RETARGET_INSTALL_ROOT:-}" ]]; then
        rm "$SRS_TEST_RETARGET_INSTALL_ROOT"
        ln -s "$SRS_TEST_RETARGET_INSTALL_ROOT_TO" "$SRS_TEST_RETARGET_INSTALL_ROOT"
    fi
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
        SRS_TEST_COLLIDE_BACKUP_BASE="${SRS_TEST_COLLIDE_BACKUP_BASE:-}" \
        SRS_TEST_RETARGET_INSTALL_ROOT="${SRS_TEST_RETARGET_INSTALL_ROOT:-}" \
        SRS_TEST_RETARGET_INSTALL_ROOT_TO="${SRS_TEST_RETARGET_INSTALL_ROOT_TO:-}" \
        SRS_TEST_RUSTUP_FAIL="${SRS_TEST_RUSTUP_FAIL:-0}" \
        SRS_TEST_RUSTUP_LINKS="$rustup_links" \
        "$root/install.sh" "$name" "$toolchain_dir" "$cargo_bin"
}

if env \
    SRS_INSTALL_ROOT="$install_root" \
    SRS_RUSTUP_BIN="$rustup_bin" \
    SRS_SLD_BIN="$sld_bin" \
    SRS_TEST_RUSTUP_LINKS="$rustup_links" \
    "$root/install.sh" --help "$toolchain_dir" "$cargo_bin" > "$scratch/option-like-name.log" 2>&1
then
    printf 'installer unexpectedly accepted an option-like toolchain name\n' >&2
    exit 1
fi
if ! grep -q 'invalid SRS toolchain name' "$scratch/option-like-name.log"; then
    printf 'installer did not explain the option-like toolchain name refusal\n' >&2
    exit 1
fi

install_snapshot
snapshot_dir="$physical_install_root/$name"

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

lock_dir="$physical_install_root/.${name}.lock"
mkdir "$lock_dir"
if SRS_INSTALL_REPLACE=1 install_snapshot > "$scratch/concurrent-install.log" 2>&1; then
    printf 'installer unexpectedly allowed concurrent installation of the same label\n' >&2
    exit 1
fi
if ! grep -q 'installation is already in progress' "$scratch/concurrent-install.log"; then
    printf 'installer did not explain the concurrent same-label refusal\n' >&2
    exit 1
fi
rmdir "$lock_dir"
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installer changed snapshot while refusing concurrent same-label installation\n' >&2
    exit 1
fi

mkdir -p \
    "$toolchain_dir/bin" \
    "$toolchain_dir/lib/rustlib/rustc-src/rust" \
    "$toolchain_dir/lib/rustlib/src/rust"
printf 'preserved rustc source\n' > "$toolchain_dir/lib/rustlib/rustc-src/rust/README"
printf 'preserved library source\n' > "$toolchain_dir/lib/rustlib/src/rust/README"
cat > "$toolchain_dir/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--print" && "${2:-}" == "host-tuple" ]]; then
    if [[ -n "${SRS_TEST_COLLIDE_BACKUP_BASE:-}" ]]; then
        mkdir -p "$SRS_TEST_COLLIDE_BACKUP_BASE.$PPID"
    fi
    if [[ -n "${SRS_TEST_RETARGET_INSTALL_ROOT:-}" ]]; then
        rm "$SRS_TEST_RETARGET_INSTALL_ROOT"
        ln -s "$SRS_TEST_RETARGET_INSTALL_ROOT_TO" "$SRS_TEST_RETARGET_INSTALL_ROOT"
    fi
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

if \
    SRS_INSTALL_REPLACE=1 \
    SRS_TEST_RUSTUP_FAIL=1 \
    SRS_TEST_COLLIDE_BACKUP_BASE="$snapshot_dir.replaced" \
    install_snapshot > "$scratch/replace-failure.log" 2>&1
then
    printf 'installer unexpectedly accepted requested fake rustup failure\n' >&2
    exit 1
fi
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installer did not roll back snapshot after rustup failure\n' >&2
    exit 1
fi
shopt -s nullglob
collision_backups=("$snapshot_dir".replaced.*)
shopt -u nullglob
if [[ "${#collision_backups[@]}" -ne 1 ]]; then
    printf 'expected exactly one injected predictable-backup collision, found %s\n' "${#collision_backups[@]}" >&2
    exit 1
fi
rm -rf "${collision_backups[@]}"

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

ln -s ../../rust-source "$toolchain_dir/lib/mutable-relative-external"
if SRS_INSTALL_REPLACE=1 install_snapshot > "$scratch/relative-external-symlink.log" 2>&1; then
    printf 'installer unexpectedly accepted a retained external relative symlink\n' >&2
    exit 1
fi
if ! grep -q 'refusing external relative symlink in SRS toolchain snapshot' "$scratch/relative-external-symlink.log"; then
    printf 'installer did not explain the retained external relative symlink refusal\n' >&2
    exit 1
fi
rm "$toolchain_dir/lib/mutable-relative-external"
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installer changed snapshot after rejecting an external relative symlink\n' >&2
    exit 1
fi

ln -s ../.. "$toolchain_dir/lib/x"
if SRS_INSTALL_REPLACE=1 install_snapshot > "$scratch/relative-parent-escape-symlink.log" 2>&1; then
    printf 'installer unexpectedly accepted a retained parent-escaping relative symlink\n' >&2
    exit 1
fi
if ! grep -q 'refusing external relative symlink in SRS toolchain snapshot' "$scratch/relative-parent-escape-symlink.log"; then
    printf 'installer did not explain the retained parent-escaping relative symlink refusal\n' >&2
    exit 1
fi
rm "$toolchain_dir/lib/x"
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo A" ]]; then
    printf 'installer changed snapshot after rejecting a parent-escaping relative symlink\n' >&2
    exit 1
fi

mkdir -p "$toolchain_dir/lib/internal-target" "$toolchain_dir/lib/-internal-target"
ln -s internal-target "$toolchain_dir/lib/internal-relative"
ln -s -- -internal-target "$toolchain_dir/lib/dash-prefixed-internal-relative"
SRS_INSTALL_REPLACE=1 install_snapshot
if [[ "$("$snapshot_dir/bin/cargo")" != "fake cargo B" ]]; then
    printf 'installer did not replace snapshot after explicit opt-in\n' >&2
    exit 1
fi
if [[ ! -L "$snapshot_dir/lib/internal-relative" || "$(readlink "$snapshot_dir/lib/internal-relative")" != "internal-target" ]]; then
    printf 'installer did not retain an internal relative symlink\n' >&2
    exit 1
fi
if [[ ! -L "$snapshot_dir/lib/dash-prefixed-internal-relative" || "$(readlink "$snapshot_dir/lib/dash-prefixed-internal-relative")" != "-internal-target" ]]; then
    printf 'installer did not retain a dash-prefixed internal relative symlink\n' >&2
    exit 1
fi
for preserved_path in \
    "$snapshot_dir/lib/rustlib/rustc-src/rust/README" \
    "$snapshot_dir/lib/rustlib/src/rust/README"
do
    if [[ ! -f "$preserved_path" ]]; then
        printf 'installer did not retain copied rust-src directory content: %s\n' "$preserved_path" >&2
        exit 1
    fi
done

retarget_physical_install_root="$scratch/retarget-physical-install-root"
retarget_other_install_root="$scratch/retarget-other-install-root"
retarget_install_root="$scratch/retarget-install-root"
retarget_name="srs-retarget-smoke"
mkdir -p "$retarget_physical_install_root" "$retarget_other_install_root"
ln -s "$retarget_physical_install_root" "$retarget_install_root"
env \
    SRS_INSTALL_ROOT="$retarget_install_root" \
    SRS_RUSTUP_BIN="$rustup_bin" \
    SRS_SLD_BIN="$sld_bin" \
    SRS_TEST_RETARGET_INSTALL_ROOT="$retarget_install_root" \
    SRS_TEST_RETARGET_INSTALL_ROOT_TO="$retarget_other_install_root" \
    SRS_TEST_RUSTUP_LINKS="$rustup_links" \
    "$root/install.sh" "$retarget_name" "$toolchain_dir" "$cargo_bin"
if [[ ! -x "$retarget_physical_install_root/$retarget_name/bin/rustc" ]]; then
    printf 'installer did not publish into the pinned physical install root\n' >&2
    exit 1
fi
if [[ -e "$retarget_other_install_root/$retarget_name" || -L "$retarget_other_install_root/$retarget_name" ]]; then
    printf 'installer followed a retargeted install-root symlink during publication\n' >&2
    exit 1
fi
if [[ "$(readlink "$rustup_links/$retarget_name")" != "$retarget_physical_install_root/$retarget_name" ]]; then
    printf 'installer did not link rustup to the pinned physical snapshot path\n' >&2
    exit 1
fi

printf 'immutable install snapshot smoke passed\n'
