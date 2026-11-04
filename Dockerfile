# RocketIDE in one container, set up the way the engine's own image is (rocket-engine/Dockerfile): the engine's
# locked environment and its pinned toolchain from scripts/provision_toolchain.sh --install, the PDK registered at start,
# then one engine shared by the web app, the agent and headless clients.
#
# CI publishes this image, so the quickest way to run it is:
#
#   docker run --rm -p 127.0.0.1:5173:5173 ghcr.io/team-rocketeda/rocketide
#   open http://localhost:5173
#
# To build it yourself, from a checkout with its submodules (git submodule update --init --recursive):
#
#   docker build -t rocketide .
#
# With no PDK at /pdk, the first start downloads the open-source sky130A onto the store volume. Keep your work and that
# download between runs with -v rocketide-store:/stores/rocketeda -v rocketide-projects:/opt/rocketide/projects.
# Your own PDK: -v /path/to/sky130A:/pdk:ro, and -e PDK_ID=... -e PDK_REVISION=... if it isn't sky130A.
#
# Model: Muse Spark, through the Meta Model API. Add your key in the app's assistant panel (it's kept on the store
# volume), or pass it from the shell with -e MODEL_API_KEY. The container's log prints every call. Without a key the
# IDE and engine checks still work.
# Headless API, from inside the container: http://127.0.0.1:8765 (loopback only, no auth).
FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/Team-RocketEDA/RocketIDE"
LABEL org.opencontainers.image.description="RocketIDE: design chips with an AI agent beside you. Every result comes from a real tool."

ARG NODE_VERSION=22.12.0
ARG UV_VERSION=0.12.23
# Passed to install.sh. Add --photonic for optical and layout runs, in a larger image.
ARG INSTALL_FLAGS="--no-desktop --container"

ENV DEBIAN_FRONTEND=noninteractive
# python3 is Ubuntu's 3.12, the engine's pin. The rest is what the engine's provisioner needs to fetch and build
# its tools (rocket-engine/Dockerfile, docs/provision-sources.md).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl git python3 python3-venv ngspice zstd \
       make cmake gcc g++ gfortran bison flex swig \
       tcl tcl-dev tk tk-dev libx11-dev \
       bzip2 xz-utils unzip sudo \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture | sed 's/amd64/x64/')" \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
       | tar -xJ --strip-components=1 -C /usr/local \
    && curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_UNMANAGED_INSTALL=/usr/local/bin sh

RUN useradd --create-home --shell /bin/bash rocketeda
WORKDIR /opt/rocketide
COPY . .
# The engine image's layout: tools in /tools, the engine store and the PDK on volumes.
ENV TOOLS_DIR=/tools \
    OSS_CAD_SUITE_DIR=/tools/oss-cad-suite \
    ROCKETEDA_HOME=/stores/rocketeda \
    PDK_SOURCE=/pdk \
    UV_CACHE_DIR=/tmp/uv-cache
RUN mkdir -p projects /tools /stores/rocketeda /pdk \
    && chown -R rocketeda:rocketeda /opt/rocketide /tools /stores /pdk
USER rocketeda

# Only Meta models run.
ENV ROCKET_MODEL=meta/muse-spark-1.3 \
    ROCKET_CREDENTIALS_FILE=/stores/rocketeda/credentials \
    ROCKET_UI_HOST=0.0.0.0 \
    ROCKET_UI_PORT=5173 \
    ROCKET_PDK_AT_START=1
RUN ./install.sh ${INSTALL_FLAGS} && rm -rf /tmp/uv-cache

VOLUME ["/pdk", "/stores/rocketeda", "/opt/rocketide/projects"]
EXPOSE 5173
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD curl -fsS http://127.0.0.1:5173/api/status >/dev/null || exit 1
CMD ["./run.sh"]
