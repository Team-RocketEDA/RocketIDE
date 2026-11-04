#!/usr/bin/env bash
# Builds RocketIDE from this checkout: the engine, its toolchain, the agent, the UI and the demo projects.
#
#   ./install.sh                  everything, including the desktop app
#   ./install.sh --no-desktop     browser only: skips the Electron download
#   ./install.sh --photonic       also the engine's SAX + GDSFactory groups (several hundred MB)
#   ./install.sh --container      the engine as its own image installs it: PDK registered when run.sh starts
#   ./install.sh --check          only report what is present
#   ./install.sh --package        also write build/rocketide-<version>.tar.gz
#   ./install.sh --release <tag>  also upload that archive to a GitHub release
#
# The engine is installed by its own scripts/install.sh, unchanged: its Python environment, the PDK it registers
# from PDK_SOURCE (default ~/.local/share/pdk/sky130A; it stops without one), and its pinned toolchain from
# scripts/provision_toolchain.sh --install. PDK_SOURCE, PDK_ID and PDK_REVISION can go in .env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DESKTOP=1 PHOTONIC=0 CONTAINER=0 CHECK=0 PACKAGE=0 TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-desktop) DESKTOP=0 ;;
    --photonic) PHOTONIC=1 ;;
    --container) CONTAINER=1 ;;
    --check) CHECK=1 ;;
    --package) PACKAGE=1 ;;
    --release) PACKAGE=1; TAG="${2:?--release needs a tag}"; shift ;;
    -h|--help) sed -n 2,14p "$0" | cut -c3-; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "Missing $1: $2" >&2; exit 1; }; }

# The bundle's .env (model, PDK); anything already exported wins.
if [[ -f .env ]]; then
  EXPORTED="$(export -p)"
  set -a; source .env; set +a
  eval "$EXPORTED"
fi

if [[ "$CHECK" == 1 ]]; then
  for tool in git node npm uv; do
    printf '%-10s %s\n' "$tool" "$(command -v "$tool" || echo missing)"
  done
  if paths="$(bash rocket-engine/scripts/provision_toolchain.sh --print-path 2>/dev/null)"; then eval "$paths"; fi
  bash rocket-engine/scripts/install.sh --check-only || true
  exec python3 -I rocket_fuel/scripts/doctor.py --no-model
fi

need git "install it from your package manager"
need node "install Node 20.12 or newer"
need npm "it ships with Node"
need uv "curl -LsSf https://astral.sh/uv/install.sh | sh"

# A release archive or Docker build already holds the submodules, without git metadata.
if [[ -d .git || -f .git ]]; then
  step "Submodules"
  git submodule update --init --recursive
fi
for part in rocket-engine rocket_fuel UIUX Demos/photonic_matmul Demos/waveform-generator Demos/albert-chip-demo; do
  [[ -n "$(ls -A "$part" 2>/dev/null)" ]] || { echo "$part is empty." >&2; exit 1; }
done

step "Engine"
if [[ "$CONTAINER" == 1 ]]; then
  # The engine's Dockerfile: locked deps without dev groups, the sealed package, then the toolchain. The PDK
  # comes later, from a volume (run.sh registers it with scripts/install.sh --pdk-only).
  (cd rocket-engine && uv sync --locked --no-dev --no-install-project && uv pip install --python .venv/bin/python --no-deps .)
  (cd rocket-engine && bash scripts/provision_toolchain.sh --install) \
    || echo "Toolchain degraded (see the REMEDY lines above); the engine reports missing tools as NOT_RUN."
else
  rocket-engine/scripts/install.sh --install
fi
if [[ "$PHOTONIC" == 1 ]]; then
  step "Engine photonic and layout groups"
  # --inexact keeps the sealed package and anything the provisioner put in the environment.
  dev=(--group dev); [[ "$CONTAINER" == 1 ]] && dev=(--no-dev)
  (cd rocket-engine && uv sync --locked --inexact "${dev[@]}" --group photonic --group layout --no-install-project \
    && uv pip install --python .venv/bin/python --no-deps .)
fi
rocket-engine/.venv/bin/python -c "import rocket_engine.composition"

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
