# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/identity-mock/Dockerfile -t amisad/identity-mock .
FROM rust:1.96-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p identity-mock

FROM debian:bookworm-slim
COPY --from=build /src/target/release/identity-mock /usr/local/bin/identity-mock
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/identity-mock"]
