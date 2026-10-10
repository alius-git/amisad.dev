# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/ads-svc/Dockerfile -t amisad/ads-svc .
FROM rust:1.98-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY components ./components
RUN cargo build --release --locked -p ads-svc

FROM debian:bookworm-slim
COPY --from=build /src/target/release/ads-svc /usr/local/bin/ads-svc
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ads-svc"]
