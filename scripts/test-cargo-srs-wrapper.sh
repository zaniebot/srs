#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_root="${SRS_WRAPPER_TEST_TMPDIR:-$HOME/code/tmp}"
mkdir -p "$scratch_root"
scratch="$(mktemp -d "$scratch_root/srs-wrapper-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

cp "$root/cargo-srs.sh" "$scratch/cargo"
chmod +x "$scratch/cargo"

cat > "$scratch/cargo-srs-real" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'ARG=%s\n' "$@"
    printf 'SLD_INCREMENTAL=%s\n' "${SLD_INCREMENTAL-<unset>}"
    printf 'CARGO_BUILD_ARTIFACT_CACHE_DIR=%s\n' "${CARGO_BUILD_ARTIFACT_CACHE_DIR-<unset>}"
    printf 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=%s\n' "${CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION-<unset>}"
    printf 'CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=%s\n' "${CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE-<unset>}"
} > "$SRS_WRAPPER_TEST_OUTPUT"
EOF
chmod +x "$scratch/cargo-srs-real"

run_wrapper() {
    local output="$1"
    shift
    env \
        -u SLD_INCREMENTAL \
        -u SRS_CARGO_ARTIFACT_CACHE \
        -u SRS_CARGO_ARTIFACT_CACHE_DIR \
        -u SRS_CARGO_ARTIFACT_CACHE_MATERIALIZATION \
        -u SRS_CARGO_ARTIFACT_CACHE_MAX_SIZE \
        -u CARGO_BUILD_ARTIFACT_CACHE_DIR \
        -u CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION \
        -u CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE \
        SRS_WRAPPER_TEST_OUTPUT="$output" \
        HOME="$scratch/home" \
        CARGO_HOME="$scratch/cargo-home" \
        "$@"
}

assert_args() {
    local output="$1"
    shift
    diff -u <(printf 'ARG=%s\n' "$@") <(grep '^ARG=' "$output")
}

default_output="$scratch/default"
run_wrapper "$default_output" "$scratch/cargo" build
assert_args "$default_output" \
    -Z artifact-cache \
    -Z host-config \
    -Z target-applies-to-host \
    --config 'target-applies-to-host=false' \
    --config 'host.rustflags=["-Zcodegen-backend=llvm"]' \
    build
grep -qx "CARGO_BUILD_ARTIFACT_CACHE_DIR=$scratch/cargo-home/srs-artifact-cache-v2" "$default_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=<unset>' "$default_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=<unset>' "$default_output"
grep -qx 'SLD_INCREMENTAL=1' "$default_output"

disabled_output="$scratch/disabled"
run_wrapper "$disabled_output" env SRS_CARGO_ARTIFACT_CACHE=0 "$scratch/cargo" build
assert_args "$disabled_output" \
    -Z artifact-cache \
    --config build.artifact-cache=false \
    -Z host-config \
    -Z target-applies-to-host \
    --config 'target-applies-to-host=false' \
    --config 'host.rustflags=["-Zcodegen-backend=llvm"]' \
    build
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_DIR=<unset>' "$disabled_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=<unset>' "$disabled_output"

alias_output="$scratch/alias"
run_wrapper "$alias_output" env \
    SRS_CARGO_ARTIFACT_CACHE_DIR="$scratch/srs-cache" \
    SRS_CARGO_ARTIFACT_CACHE_MATERIALIZATION=copy \
    SRS_CARGO_ARTIFACT_CACHE_MAX_SIZE=100GiB \
    "$scratch/cargo" build
grep -qx "CARGO_BUILD_ARTIFACT_CACHE_DIR=$scratch/srs-cache" "$alias_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=copy' "$alias_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=100GiB' "$alias_output"

override_output="$scratch/override"
run_wrapper "$override_output" env \
    SRS_CARGO_ARTIFACT_CACHE_DIR="$scratch/srs-cache" \
    SRS_CARGO_ARTIFACT_CACHE_MATERIALIZATION=copy \
    SRS_CARGO_ARTIFACT_CACHE_MAX_SIZE=100GiB \
    CARGO_BUILD_ARTIFACT_CACHE_DIR="$scratch/cargo-cache" \
    CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=hardlink \
    CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=200GiB \
    "$scratch/cargo" build
grep -qx "CARGO_BUILD_ARTIFACT_CACHE_DIR=$scratch/cargo-cache" "$override_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=hardlink' "$override_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=200GiB' "$override_output"

printf 'SRS Cargo wrapper smoke test passed\n'
