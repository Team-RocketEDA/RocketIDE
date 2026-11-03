# RocketIDE in one container: the React app and workspace server on one port, the engine started over its stdio
# adapter by that server, and optionally the engine's HTTP API on loopback inside the container.
#
#   docker build -t rocketide .
#   docker run --rm -p 127.0.0.1:5173:5173 -v rocketide-projects:/opt/rocketide/projects rocketide
#   open http://localhost:5173
#
# Build from a checkout with its submodules present: git submodule update --init --recursive
#
# Model: the free default needs no key. For Muse Spark add
#   -e ROCKET_MODEL=meta/muse-spark-1.3 -e MODEL_API_KEY=...
# Headless API, from inside the container:
#   docker run ... rocketide ./run.sh --engine-http 8765
# PDKs are too large for an image (sky130A is about 12 GB). Mount one for PDK checks:
#   -v /path/to/pdk:/pdk:ro -e PDK_ROOT=/pdk -e ROCKET_PDK_ROOTS=/pdk
FROM ubuntu:24.04

ARG NODE_VERSION=22.12.0
ARG UV_VERSION=0.12.23
# Passed to install.sh. Remove --photonic for a smaller image without optical and layout runs.
ARG INSTALL_FLAGS="--no-desktop --photonic"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl git python3 xz-utils ngspice iverilog verilator yosys \
    && for optional in magic netgen-lvs klayout xschem; do \
         apt-get install -y --no-install-recommends "$optional" || echo "Skipping $optional: not in this release"; \
       done \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture | sed 's/amd64/x64/')" \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
       | tar -xJ --strip-components=1 -C /usr/local \
    && curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_UNMANAGED_INSTALL=/usr/local/bin sh

RUN useradd --create-home --shell /bin/bash rocketeda
WORKDIR /opt/rocketide
COPY . .
RUN mkdir -p projects && chown -R rocketeda:rocketeda /opt/rocketide
USER rocketeda

# The free model works with no key; set ROCKET_MODEL and MODEL_API_KEY at run time for another.
ENV ROCKET_MODEL=opencode/beam-free \
    ROCKET_UI_HOST=0.0.0.0 \
    ROCKET_UI_PORT=5173
RUN ./install.sh ${INSTALL_FLAGS}

VOLUME ["/opt/rocketide/projects"]
EXPOSE 5173
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD curl -fsS http://127.0.0.1:5173/api/status >/dev/null || exit 1
CMD ["./run.sh"]
