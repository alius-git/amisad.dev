# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/platform-svc/Dockerfile -t amisad/platform-svc .
FROM rust:1.96-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p platform-svc

FROM debian:bookworm-slim
COPY --from=build /src/target/release/platform-svc /usr/local/bin/platform-svc
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/platform-svc"]