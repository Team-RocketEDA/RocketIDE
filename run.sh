#!/usr/bin/env bash
# Starts RocketIDE.
#
#   ./run.sh                      in the browser, http://localhost:5173
#   ./run.sh desktop              as the desktop app
#   ./run.sh --engine-http 8765   also the engine's HTTP API, for headless requests
#
# Set ROCKET_UI_HOST / ROCKET_UI_PORT to change the address. The UI server starts the engine (over its
# stdio MCP adapter) and the agent for whichever project is open.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=web
ENGINE_HTTP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    web|desktop) MODE="$1" ;;
    --engine-http) ENGINE_HTTP="${2:?--engine-http needs a port}"; shift ;;
    -h|--help) sed -n 2,9p "$0" | cut -c3-; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# .env fills in what isn't set; anything already exported wins, such as docker run -e.
if [[ -f "$ROOT/.env" ]]; then
  EXPORTED="$(export -p)"
  set -a; source "$ROOT/.env"; set +a
  eval "$EXPORTED"
fi

export ROCKET_ENGINE_HOME="$ROOT/rocket-engine"
export ROCKET_FUEL_HOME="$ROOT/rocket_fuel"
export ROCKET_PROJECTS_DIR="${ROCKET_PROJECTS_DIR:-$ROOT/projects}"
export ROCKET_UI_ROOT="$ROOT/UIUX"
# Keeps uv from syncing the dev group away from what install.sh chose.
export UV_NO_SYNC=1

[[ -f "$ROOT/UIUX/dist-server/serve.js" ]] || { echo "Not built yet. Run ./install.sh first." >&2; exit 1; }
"$ROOT/scripts/seed-projects.sh" >/dev/null

if [[ -n "$ENGINE_HTTP" ]]; then
  (cd "$ROOT/rocket-engine" && exec uv run --quiet python "$ROOT/scripts/engine-http.py" --port "$ENGINE_HTTP") &
  HTTP_PID=$!
  trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT
fi

cd "$ROOT/UIUX"
if [[ "$MODE" == desktop ]]; then
  [[ -f dist-electron/main.js ]] || { echo "No desktop build. Run ./install.sh without --no-desktop." >&2; exit 1; }
  npx electron .
else
  node dist-server/serve.js
fi
