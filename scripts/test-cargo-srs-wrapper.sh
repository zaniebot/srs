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

default_output="$scratch/default"
run_wrapper "$default_output" "$scratch/cargo" build
grep -qx 'ARG=artifact-cache' "$default_output"
grep -qx "CARGO_BUILD_ARTIFACT_CACHE_DIR=$scratch/cargo-home/srs-artifact-cache-v2" "$default_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=hardlink' "$default_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=<unset>' "$default_output"
grep -qx 'SLD_INCREMENTAL=1' "$default_output"

disabled_output="$scratch/disabled"
run_wrapper "$disabled_output" env SRS_CARGO_ARTIFACT_CACHE=0 "$scratch/cargo" build
grep -qx 'ARG=build.artifact-cache=false' "$disabled_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_DIR=<unset>' "$disabled_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=<unset>' "$disabled_output"

override_output="$scratch/override"
run_wrapper "$override_output" env \
    SRS_CARGO_ARTIFACT_CACHE_DIR="$scratch/srs-cache" \
    SRS_CARGO_ARTIFACT_CACHE_MATERIALIZATION=copy \
    SRS_CARGO_ARTIFACT_CACHE_MAX_SIZE=100GiB \
    CARGO_BUILD_ARTIFACT_CACHE_DIR="$scratch/cargo-cache" \
    CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=hardlink \
    "$scratch/cargo" build
grep -qx "CARGO_BUILD_ARTIFACT_CACHE_DIR=$scratch/cargo-cache" "$override_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MATERIALIZATION=hardlink' "$override_output"
grep -qx 'CARGO_BUILD_ARTIFACT_CACHE_MAX_SIZE=100GiB' "$override_output"

printf 'SRS Cargo wrapper smoke test passed\n'
