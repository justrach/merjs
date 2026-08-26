# merjs Dockerfile — multi-stage, multi-arch, distroless-friendly.
#
# Quick start:
#   docker build -t merjs .
#   docker run --rm -p 3000:3000 merjs
#
# Build a specific arch:
#   docker buildx build --platform linux/amd64,linux/arm64 -t merjs .

# ── Stage 1: Build ───────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

# Pin Zig version. Match build.zig.zon `minimum_zig_version`.
# 0.17.0-dev snapshots live under /builds/, not /download/<version>/.
ARG ZIG_VERSION=0.17.0-dev.1862+40ebd8162

RUN apt-get update \
    && apt-get install -y --no-recommends curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig (auto-detect arch). Both x86_64 and aarch64 are supported.
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://ziglang.org/builds/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig \
    && zig version

WORKDIR /app

# Copy build configuration first to maximize Docker layer cache reuse.
COPY build.zig build.zig.zon ./

# Pre-warm the package cache (best-effort; ignore failures on first build).
RUN zig build --help >/dev/null 2>&1 || true

# Now copy the rest of the source.
COPY . .

# Clean any cached build artifacts that may have been copied in.
RUN rm -rf .zig-cache zig-out src/generated

RUN zig build codegen \
    && zig build --release=small

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/justrach/merjs"
LABEL org.opencontainers.image.description="merjs — Next.js-style web framework written in Zig."
LABEL org.opencontainers.image.licenses="MIT"

# tini = proper PID 1 (forwards signals, reaps zombies). Only ~80KB.
# ca-certificates = HTTPS for outgoing fetch.zig calls.
# wget = HEALTHCHECK probe (also handy for debugging).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tini wget \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user — required by many PaaS (OpenShift, Cloud Run, k8s).
RUN useradd --system --create-home --shell /usr/sbin/nologin --uid 10001 merjs

WORKDIR /app

COPY --from=builder --chown=merjs:merjs /app/zig-out/bin/merjs ./merjs
COPY --from=builder --chown=merjs:merjs /app/examples/site/public ./public

USER merjs

# PORT is honored by main.zig (PaaS standard). Override with `-e PORT=8080`.
ENV PORT=3000 \
    HOST=0.0.0.0

EXPOSE 3000

# Liveness probe — relies on the `/_mer/health` endpoint added in main.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider "http://127.0.0.1:${PORT}/_mer/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/merjs"]
CMD ["--no-dev"]
