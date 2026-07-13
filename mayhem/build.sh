#!/usr/bin/env bash
#
# arrow-rs/mayhem/build.sh — build the cargo-fuzz target as a sanitized libFuzzer binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS) and pre-build the upstream test
# suite so mayhem/test.sh only RUNS it.
#
# Toolchains (installed by mayhem/Dockerfile under /opt/toolchains/rust):
#   - fuzz build: $RUST_NIGHTLY (cargo-fuzz needs nightly for -Zsanitizer=address),
#     selected explicitly via RUSTUP_TOOLCHAIN (overrides upstream's rust-toolchain.toml).
#   - test build: upstream's own pinned toolchain (rust-toolchain.toml -> 1.96.1),
#     auto-selected by rustup — exactly what upstream CI uses.
#
# Targets (mayhem/fuzz/fuzz_targets/*.rs — ported from the old fork's parquet/fuzz crate):
#   parse_metadata — decodes fuzzer bytes as a Parquet metadata footer via
#                    parquet::file::metadata::ParquetMetaDataReader::decode_metadata.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): this FIRST (online) build populates the cargo registry
# under $CARGO_HOME; the PATCH tier re-runs this script OFFLINE with CARGO_NET_OFFLINE=true
# and resolves crates from that cache. Do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Rust: sanitizer instrumentation flows through RUSTFLAGS (-Zsanitizer=address), not clang's
# $SANITIZER_FLAGS — rustc ignores clang flags. Declared for contract parity; the cc-built C/C++
# CUs (libfuzzer-sys' libFuzzer) inherit CFLAGS/CXXFLAGS below.
: "${SANITIZER_FLAGS:=}"

# ── DWARF < 4 debug-info contract (§6.2 item 10) ─────────────────────────────────────
# The rlenv runtime may export RUST_DEBUG_FLAGS before the offline re-run; the default
# forces DWARF 2 so Mayhem triage / gdb can resolve project source lines.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

# Rust's ASan runtime archive is compiled with the nightly's bundled LLVM (DWARF 5) and is
# linked BEFORE project code — strip its debug sections so it contributes no .debug_info.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
  echo "Stripping debug info from Rust ASan runtime (DWARF < 4): $ASAN_RT"
  objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 there too.
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# The cargo-fuzz crate is ADDITIVE under mayhem/fuzz/ (upstream ships no fuzz crate on
# the current tip; the old fork's parquet/fuzz harness was relocated here).
FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=(parse_metadata)
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (toolchain $RUST_NIGHTLY, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTUP_TOOLCHAIN="$RUST_NIGHTLY" RUSTFLAGS="$FUZZ_RUSTFLAGS" \
    cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
done

TARGET_DIR="$(RUSTUP_TOOLCHAIN="$RUST_NIGHTLY" cargo metadata --no-deps --format-version 1 \
  --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
echo "fuzz target_directory: $TARGET_DIR"

REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    ls -la "$REL" >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Pre-build the upstream test suite (normal flags, upstream's pinned toolchain) ─────
# mayhem/test.sh only RUNS it. Excluded workspace members (see mayhem/test.sh header):
#   arrow-pyarrow — pyo3 links a Python interpreter w/ pyarrow (not in the image); 0 tests.
#   gen           — arrow-flight's protobuf codegen tool (needs protoc); ships no tests.
echo "=== cargo test --no-run (pre-building the upstream test suite) ==="
RUSTFLAGS="" cargo test --no-run --workspace \
  --exclude arrow-pyarrow --exclude gen --jobs "$MAYHEM_JOBS"

# Drop incremental caches (test binaries in target/debug/deps stay); keeps the image
# small enough for hosted CI runner disks.
rm -rf target/debug/incremental "$TARGET_DIR"/*/release/incremental 2>/dev/null || true

echo "build.sh complete:"
ls -la /mayhem/parse_metadata
