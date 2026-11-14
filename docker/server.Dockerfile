# syntax=docker/dockerfile:1

## Stage 1: build the Rust server
FROM rust:slim AS builder

ARG GITHUB_USER=7ejasVijay
ARG GITHUB_BRANCH=main

RUN apt-get update && apt-get install -y git pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

ARG CACHEBUST=1
RUN --mount=type=secret,id=github_token \
    git clone --branch ${GITHUB_BRANCH} \
    https://${GITHUB_USER}:$(cat /run/secrets/github_token)@github.com/${GITHUB_USER}/breakoutiq-server.git /src

WORKDIR /src
RUN cargo build --release

## Stage 2: minimal runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/breakoutIQ-server /usr/local/bin/breakoutiq-server
# The base tables, loaded into a new database by services.ps1 (the server creates everything else itself).
COPY --from=builder /src/scripts/base_schema.sql /usr/local/share/breakoutiq/base_schema.sql

EXPOSE 3001
CMD ["breakoutiq-server"]
