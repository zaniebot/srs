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

## Build

The source repositories are intentionally owned by this directory:

```bash
git clone https://github.com/rust-lang/rust.git repos/rust
git clone https://github.com/bytecodealliance/wasmtime.git repos/cranelift
```

After the Rust fork carries the SRS Cranelift patches:

```bash
./build.sh
./install.sh
./prove-uv.sh ../uv
```

The default rustup toolchain name is `srs`. The build, installer, and proof
scripts accept overrides through their command-line arguments or documented
environment variables in the scripts.
