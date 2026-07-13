# syntax=docker/dockerfile:1.7
#
# arrow-rs commit-image Dockerfile — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). arrow-rs is a RUST workspace; the base ships NO Rust
# toolchain, so this image installs rustup with TWO toolchains under a shared,
# $HOME-independent prefix (/opt/toolchains/rust):
#   - 1.96.1  — the toolchain upstream pins in rust-toolchain.toml; rustup auto-selects
#               it inside the repo, so `cargo test` (mayhem/test.sh) runs on exactly the
#               toolchain upstream CI uses.
#   - a dated nightly — required by cargo-fuzz for -Zsanitizer=address (the OSS-Fuzz
#               Rust ASan path); build.sh selects it explicitly (RUSTUP_TOOLCHAIN) for
#               the fuzz build only.
#
# Build (from the repo root, on the `mayhem` branch, submodules checked out):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t arrow-rs-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Declared for parity with the C/C++ template; Rust instrumentation is driven via RUSTFLAGS.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Upstream's pinned toolchain (rust-toolchain.toml) + the nightly cargo-fuzz needs.
ARG RUST_STABLE=1.96.1
ARG RUST_NIGHTLY=nightly-2026-06-20
ARG CARGO_FUZZ_VERSION=0.12.0

# Rust toolchains at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) so the
# air-gapped PATCH re-run of build.sh finds the same registry cache under any $HOME.
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    RUST_NIGHTLY=${RUST_NIGHTLY} \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH} \
    # Test data the arrow / parquet test suites read (git submodules, baked into the image).
    ARROW_TEST_DATA=/mayhem/testing/data \
    PARQUET_TEST_DATA=/mayhem/parquet-testing/data \
    # Keep the (very large) workspace test build small enough for hosted CI runners:
    # no incremental caches, line-tables-only debuginfo for the dev/test profile.
    # Set as image ENV so build.sh (cargo test --no-run) and test.sh (cargo test) see
    # identical settings and cargo's fingerprints match (no rebuild at test time).
    CARGO_INCREMENTAL=0 \
    CARGO_PROFILE_DEV_DEBUG=line-tables-only

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain "$RUST_STABLE"; \
    rustup toolchain install "$RUST_NIGHTLY" --profile minimal; \
    rustup component add rust-src --toolchain "$RUST_NIGHTLY"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    rm -f /tmp/rustup-init.sh; \
    # Hand the whole prefix to mayhem (2000): the commit build AND the air-gapped PATCH
    # re-run both run as mayhem and need to read/refresh the registry cache.
    chown -R 2000:2000 /opt/toolchains/rust; \
    rustc --version; cargo --version; cargo fuzz --version
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history and the testing/ + parquet-testing/ submodules) is copied to /mayhem.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# A fresh CI checkout may carry only gitlinks for the testing/ + parquet-testing/ submodules;
# materialize them ONLINE here (this first build) so the image is self-contained and the
# offline PATCH re-run of build.sh / test.sh finds the golden test data in place.
RUN git submodule update --init --recursive

RUN bash mayhem/build.sh

# Run arrow-rs's real test suite at build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
