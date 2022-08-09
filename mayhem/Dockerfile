# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

RUN echo building instrumented harnesses && \
    bash -c "pushd parquet/fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv parquet/fuzz/target/x86_64-unknown-linux-gnu/release/parse_metadata /parse_metadata && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd parquet/fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv parquet/fuzz/target/release/parse_metadata /parse_metadata_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /parse_metadata /parse_metadata_no_inst /
RUN mkdir /testsuite
COPY --from=builder /src/parquet/fuzz/corpus/parse_metadata/books.parquet /testsuite/
