#!/usr/bin/env bash
# Builds RocketIDE from this checkout: the engine, the agent, the UI and the demo projects.
#
#   ./install.sh                  everything, including the desktop app
#   ./install.sh --no-desktop     browser only: skips the Electron download
#   ./install.sh --photonic       also the engine's SAX + GDSFactory groups (several hundred MB)
#   ./install.sh --toolchain      also the engine's pinned EDA toolchain (long; builds from source)
#   ./install.sh --check          only report what is present
#   ./install.sh --package        also write build/rocketide-<version>.tar.gz
#   ./install.sh --release <tag>  also upload that archive to a GitHub release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DESKTOP=1 PHOTONIC=0 TOOLCHAIN=0 CHECK=0 PACKAGE=0 TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-desktop) DESKTOP=0 ;;
    --photonic) PHOTONIC=1 ;;
    --toolchain) TOOLCHAIN=1 ;;
    --check) CHECK=1 ;;
    --package) PACKAGE=1 ;;
    --release) PACKAGE=1; TAG="${2:?--release needs a tag}"; shift ;;
    -h|--help) sed -n 2,10p "$0" | cut -c3-; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "Missing $1: $2" >&2; exit 1; }; }

if [[ "$CHECK" == 1 ]]; then
  for tool in git node npm uv ngspice iverilog verilator yosys klayout magic netgen xschem; do
    printf '%-10s %s\n' "$tool" "$(command -v "$tool" || echo missing)"
  done
  exec python3 -I rocket_fuel/scripts/doctor.py --no-model
fi

need git "install it from your package manager"
need node "install Node 20.12 or newer"
need npm "it ships with Node"
need uv "curl -LsSf https://astral.sh/uv/install.sh | sh"
command -v ngspice >/dev/null || echo "Warning: ngspice is not on PATH, so SPICE checks will report NOT_RUN."

# A release archive or Docker build already holds the submodules, without git metadata.
if [[ -d .git || -f .git ]]; then
  step "Submodules"
  git submodule update --init --recursive
fi
for part in rocket-engine rocket_fuel UIUX Demos/photonic_matmul Demos/waveform-generator Demos/albert-chip-demo; do
  [[ -n "$(ls -A "$part" 2>/dev/null)" ]] || { echo "$part is empty." >&2; exit 1; }
done

step "Engine (Python)"
groups=()
[[ "$PHOTONIC" == 1 ]] && groups+=(--group photonic --group layout)
(cd rocket-engine && uv sync --locked --no-dev ${groups[@]+"${groups[@]}"})
(cd rocket-engine && uv run --no-sync --quiet python -c "import rocket_engine.composition")
if [[ "$TOOLCHAIN" == 1 ]]; then
  step "Engine toolchain"
  (cd rocket-engine && bash scripts/provision_toolchain.sh --install)
fi

step "Agent (pinned opencode)"
(cd rocket_fuel && npm ci --prefer-offline --no-audit --no-fund)
(cd rocket_fuel/mcp-stub && uv sync --locked --no-dev)

step "UI"
if [[ "$DESKTOP" == 1 ]]; then
  (cd UIUX && npm ci --prefer-offline --no-audit --no-fund)
else
  (cd UIUX && ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci --prefer-offline --no-audit --no-fund --ignore-scripts)
fi
(cd UIUX && npm run --silent build && npm run --silent build:server)
if [[ "$DESKTOP" == 1 ]]; then
  (cd UIUX && npm run --silent build:electron)
fi

[[ -f .env ]] || cp .env.example .env

step "Demo projects"
scripts/seed-projects.sh

if [[ "$PACKAGE" == 1 ]]; then
  step "Package"
  version="${TAG:-$(git describe --tags --always 2>/dev/null || echo dev)}"
  archive="build/rocketide-$version.tar.gz"
  mkdir -p build
  { git ls-files --recurse-submodules
    find UIUX/dist UIUX/dist-server -type f
    [[ -d UIUX/dist-electron ]] && find UIUX/dist-electron -type f
    true
  } | tar -czf "$archive" -T -
  ls -lh "$archive"
  if [[ -n "$TAG" ]]; then
    need gh "needed to upload a release"
    gh release create "$TAG" "$archive" --title "RocketIDE $TAG" --generate-notes
  fi
fi

printf '\nRocketIDE is ready. Start it with ./run.sh\n'
