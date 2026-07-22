# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/audit-svc/Dockerfile -t amisad/audit-svc .
FROM rust:1.96-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p audit-svc

FROM debian:bookworm-slim
COPY --from=build /src/target/release/audit-svc /usr/local/bin/audit-svc
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/audit-svc"]