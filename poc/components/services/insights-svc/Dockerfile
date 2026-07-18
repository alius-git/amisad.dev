# Build from the poc/ workspace root (the Rust workspace lives there):
#   docker build -f components/services/insights-svc/Dockerfile -t amisad/insights-svc .
FROM rust:1.83-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY components ./components
RUN cargo build --release -p insights-svc

FROM debian:bookworm-slim
COPY --from=build /src/target/release/insights-svc /usr/local/bin/insights-svc
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/insights-svc"]