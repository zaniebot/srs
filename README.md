# SRS

SRS is the slop Rust stack: a forked Rust toolchain that carries the patched
Cranelift backend needed to compile Astral workloads on macOS arm64.

## Layout

- `repos/rust/`: the Rust fork that builds the toolchain and owns the
  `compiler/rustc_codegen_cranelift` integration.
- `repos/cranelift/`: the patched Wasmtime/Cranelift checkout consumed by the
  backend in the Rust fork.
- `bootstrap.toml`: Rust bootstrap configuration for the SRS toolchain build.
- `build.sh`: builds a stage 2 Rust toolchain with LLVM and Cranelift backends,
  plus Cargo from the Rust tree's Cargo submodule.
- `install.sh`: links the built stage 2 toolchain into rustup under a custom
  name and attaches the built Cargo binary to that linked sysroot.
- `prove-uv.sh`: builds `uv` with the installed SRS toolchain and Cranelift.

The bootstrap config keeps LLVM first in `rust.codegen-backends`. This leaves
the Rust compiler and default Cargo behavior on LLVM while the uv proof opts the
dev profile into Cranelift explicitly.

## Quick Start

Initialize the pinned Rust and Cranelift source trees after cloning SRS:

```bash
git submodule update --init repos/rust repos/cranelift
```

Build a stage 2 toolchain and link it into rustup as `srs`:

```bash
./build.sh
./install.sh
```

Check that rustup can see it:

```bash
rustc +srs -Vv
cargo +srs -Vv
```

`./build.sh` is the slow step. Re-run it after changing Rust, cg_clif, or
Cranelift. `./install.sh` relinks the resulting stage 2 sysroot; it does not
copy the toolchain.

## Usage

The SRS toolchain still has LLVM available and uses it by default:

```bash
cargo +srs build
```

Opt a Cargo profile into the SRS Cranelift backend explicitly:

```bash
CARGO_PROFILE_DEV_CODEGEN_BACKEND=cranelift \
    cargo +srs build -Zcodegen-backend
```

The repository includes a uv proof that keeps its Cargo home and build output
under SRS:

```bash
./prove-uv.sh ../uv
```

Use a separate rustup toolchain name when keeping multiple SRS builds linked:

```bash
./install.sh srs-dev
SRS_TOOLCHAIN=srs-dev ./prove-uv.sh ../uv
```

The installer also accepts an explicit stage 2 sysroot and Cargo binary:

```bash
./install.sh srs-dev /path/to/stage2 /path/to/cargo
```

## Development

Development happens inside each submodule. Commit Rust and Cranelift changes in
their owning repositories, then stage the updated submodule paths in SRS to pin
the integrated stack revision.

```bash
git -C repos/cranelift commit
git -C repos/rust commit
git add repos/cranelift repos/rust
git commit
```

After pulling an SRS change that advances either source pin, update the
submodules before rebuilding:

```bash
git submodule update --init repos/rust repos/cranelift
```

Fresh clones need the configured submodule remotes to contain the pinned SRS
Rust and Cranelift commits.
