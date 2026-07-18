# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/edge/slice-runtime/Dockerfile -t amisad/slice-runtime .
FROM rust:1.83-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p slice-runtime

FROM debian:bookworm-slim
COPY --from=build /src/target/release/slice-runtime /usr/local/bin/slice-runtime
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/slice-runtime"]