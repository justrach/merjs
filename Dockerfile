# merjs Dockerfile — multi-stage build
# Usage:
#   docker build -t merjs .
#   docker run -p 3000:3000 merjs

# ── Stage 1: Build ───────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

ARG ZIG_VERSION=0.15.2

RUN apt-get update && apt-get install -y curl xz-utils && rm -rf /var/lib/apt/lists/*

# Install Zig (auto-detect arch)
RUN ARCH=$(uname -m) && \
    curl -sL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app
COPY . .
RUN rm -rf .zig-cache zig-out src/generated

RUN zig build codegen
RUN zig build wasm
RUN zig build -Doptimize=ReleaseSmall

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/zig-out/bin/merjs ./merjs
COPY --from=builder /app/examples/site/public ./public

EXPOSE 3000
CMD ["./merjs", "--host", "0.0.0.0"]
