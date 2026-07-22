# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/seller-svc/Dockerfile -t amisad/seller-svc .
FROM rust:1.96-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p seller-svc

FROM debian:bookworm-slim
COPY --from=build /src/target/release/seller-svc /usr/local/bin/seller-svc
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/seller-svc"]