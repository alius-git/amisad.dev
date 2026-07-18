# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/fabric-coordinator/Dockerfile -t amisad/fabric-coordinator .
FROM rust:1.83-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p fabric-coordinator

FROM debian:bookworm-slim
COPY --from=build /src/target/release/fabric-coordinator /usr/local/bin/fabric-coordinator
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/fabric-coordinator"]