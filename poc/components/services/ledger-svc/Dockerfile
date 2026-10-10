# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/ledger-svc/Dockerfile -t amisad/ledger-svc .
FROM rust:1.98-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY components ./components
RUN cargo build --release --locked -p ledger-svc

FROM debian:bookworm-slim
COPY --from=build /src/target/release/ledger-svc /usr/local/bin/ledger-svc
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ledger-svc"]
