#!/usr/bin/env bash
#
# arrow-rs/mayhem/test.sh — RUN apache/arrow-rs's own upstream test suite (`cargo test`
# across the workspace) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: arrow-rs ships a large real assertion suite — thousands of unit +
# integration tests across the arrow-* and parquet-* crates (known-answer array kernels,
# round-trip IPC/CSV/JSON/Parquet readers+writers against the committed testing/ and
# parquet-testing/ golden data, parquet_derive_test, parquet-variant conformance, etc.).
# These assert concrete values / golden files, so a no-op / exit(0) patch CANNOT pass.
# This script only RUNS the suite; mayhem/build.sh pre-compiled it (cargo test --no-run)
# with upstream's own pinned toolchain (rust-toolchain.toml).
#
# Skipped upstream workspace members (with reasons):
#   arrow-pyarrow — requires a Python interpreter with the pyarrow wheel (upstream CI uses
#                   a dedicated Python job); the crate itself contains no #[test]s.
#   gen           — arrow-flight's protobuf codegen tool (requires protoc); ships no tests.
#   arrow-pyarrow-testing / arrow-pyarrow-integration-testing — already excluded from the
#                   workspace by upstream's own Cargo.toml for the same Python reason.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi
if [ ! -d "${ARROW_TEST_DATA:-testing/data}" ] || [ ! -d "${PARQUET_TEST_DATA:-parquet-testing/data}" ]; then
  echo "testing/ or parquet-testing/ submodule data missing — the image must bake the submodules in" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (arrow-rs workspace unit + integration suite) ==="
# Same exclusions as build.sh (see header). RUSTFLAGS cleared so the run inherits nothing
# from the sanitizer build; upstream's pinned toolchain is auto-selected by rust-toolchain.toml.
out="$(RUSTFLAGS="" cargo test --workspace --exclude arrow-pyarrow --exclude gen \
  --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; ...
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
