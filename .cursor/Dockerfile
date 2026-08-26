# Cloud Agent base image for merjs.
#
# Installs the pinned Zig toolchain (matching build.zig.zon
# `minimum_zig_version`) plus the tools needed to build and run the
# framework and its demo site. Repository dependencies and route codegen
# are handled by the `install` step in .cursor/environment.json, not here.

FROM ubuntu:24.04

# Keep in sync with build.zig.zon `minimum_zig_version` and the root Dockerfile.
ARG ZIG_VERSION=0.17.0-dev.1862+40ebd8162

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# Install Zig (auto-detect arch). 0.17.0-dev snapshots live under /builds/.
RUN ARCH=$(uname -m) \
    && curl -fsSL "https://ziglang.org/builds/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig \
    && zig version

USER ubuntu
