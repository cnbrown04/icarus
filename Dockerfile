# Single image: icarus-server binary + the built website (PLAN.md §12.1, §13.1).
# Build: docker build -t icarus .
# Run:   see docker-compose.yml and docs/deploy.md

FROM node:22-bookworm-slim AS web
WORKDIR /src/web
RUN corepack enable
COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm build

FROM rust:1-bookworm AS server
WORKDIR /src/server
COPY server/ ./
RUN cargo build --release --locked --bin icarus-server

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /app icarus
WORKDIR /app
COPY --from=server /src/server/target/release/icarus-server /app/icarus-server
COPY --from=web /src/web/dist /app/web
ENV ICARUS_BIND=0.0.0.0:8080 \
    ICARUS_WEB_DIR=/app/web \
    RUST_LOG=info
USER icarus
EXPOSE 8080
ENTRYPOINT ["/app/icarus-server"]
