# RocketIDE in one container, set up the way the engine's own image is (rocket-engine/Dockerfile): the engine's
# locked environment and its pinned toolchain from scripts/provision_toolchain.sh --install, the PDK on a volume
# registered at start, then one engine shared by the web app, the agent and headless clients.
#
#   docker build -t rocketide .
#   docker run --rm -p 127.0.0.1:5173:5173 \
#     -v /path/to/sky130A:/pdk:ro -v rocketide-store:/stores/rocketeda -v rocketide-projects:/opt/rocketide/projects \
#     rocketide
#   open http://localhost:5173
#
# Build from a checkout with its submodules present: git submodule update --init --recursive
# The PDK is never in the image (sky130A is about 12 GB). Without one at /pdk the container stops, as the engine's
# does. Another PDK: -e PDK_ID=... -e PDK_REVISION=... (see rocket-engine/scripts/install.sh).
#
# Model: the free default needs no key. For Muse Spark add
#   -e ROCKET_MODEL=meta/muse-spark-1.3 -e MODEL_API_KEY=...
# Headless API, from inside the container: http://127.0.0.1:8765 (loopback only, no auth).
FROM ubuntu:24.04

ARG NODE_VERSION=22.12.0
ARG UV_VERSION=0.12.23
# Passed to install.sh. Remove --photonic for a smaller image without optical and layout runs.
ARG INSTALL_FLAGS="--no-desktop --photonic --container"

ENV DEBIAN_FRONTEND=noninteractive
# python3 is Ubuntu's 3.12, the engine's pin. The rest is what the engine's provisioner needs to fetch and build
# its tools (rocket-engine/Dockerfile, docs/provision-sources.md).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl git python3 python3-venv \
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

# The free model works with no key; set ROCKET_MODEL and MODEL_API_KEY at run time for another.
ENV ROCKET_MODEL=opencode/beam-free \
    ROCKET_UI_HOST=0.0.0.0 \
    ROCKET_UI_PORT=5173 \
    ROCKET_PDK_AT_START=1
RUN ./install.sh ${INSTALL_FLAGS} && rm -rf /tmp/uv-cache

VOLUME ["/pdk", "/stores/rocketeda", "/opt/rocketide/projects"]
EXPOSE 5173
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD curl -fsS http://127.0.0.1:5173/api/status >/dev/null || exit 1
CMD ["./run.sh"]
