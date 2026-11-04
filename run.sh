#!/usr/bin/env bash
# Starts RocketIDE: the engine's provisioned tools on PATH, one engine, then every client on that engine.
#
#   ./run.sh            the engine and the web app, http://localhost:5173
#   ./run.sh desktop    the engine, the web app and the desktop window, all at once
#   ./run.sh replay     no key needed: the assistant replays a real recorded Muse Spark session (docs/sample-runs)
#
# The agent for whichever project is open attaches to the same engine over MCP. Headless clients use it too, at
# http://127.0.0.1:8765 (ROCKET_ENGINE_PORT): POST /projects/<name>/call, or the engine's own HTTP API at
# /projects/<name>/api/. Set ROCKET_UI_HOST / ROCKET_UI_PORT to change the web app's address.
#
# Every model call goes to the Meta Model API through rocket_fuel/scripts/meta-relay.py, which prints it in this
# terminal with the model name the API's response reports, and saves the same facts to logs/meta-calls.jsonl. Keys
# and prompts are never printed or saved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=web
while [[ $# -gt 0 ]]; do
  case "$1" in
    web|desktop|replay) MODE="$1" ;;
    -h|--help) sed -n 2,14p "$0" | cut -c3-; exit 0 ;;
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

ENGINE="$ROOT/rocket-engine"
export ROCKET_ENGINE_HOME="$ENGINE"
export ROCKET_FUEL_HOME="$ROOT/rocket_fuel"
export ROCKET_PROJECTS_DIR="${ROCKET_PROJECTS_DIR:-$ROOT/projects}"
export ROCKET_UI_ROOT="$ROOT/UIUX"
# Keeps uv from syncing the agent's tool stub to its dev group at every start.
export UV_NO_SYNC=1
ENGINE_PORT="${ROCKET_ENGINE_PORT:-8765}"
UI_PORT="${ROCKET_UI_PORT:-5173}"

[[ -x "$ENGINE/.venv/bin/python" && -f "$ROOT/UIUX/dist-server/serve.js" ]] || { echo "Not built yet. Run ./install.sh first." >&2; exit 1; }

# 1. The tools the engine's provisioner installed, as the engine itself prints them.
if paths="$(bash "$ENGINE/scripts/provision_toolchain.sh" --print-path 2>/dev/null)"; then
  eval "$paths"
else
  echo "No provisioned toolchain found; using whatever EDA tools are on PATH (install.sh provisions them)." >&2
fi

# In the container the PDK arrives as a volume, so it is registered here, the way the engine's own image does.
if [[ "${ROCKET_PDK_AT_START:-0}" == 1 ]]; then
  "$ENGINE/scripts/install.sh" --pdk-only || {
    echo "No PDK to register. Mount one at ${PDK_SOURCE:-/pdk}: docker run -v /path/to/sky130A:/pdk:ro ..." >&2
    exit 1
  }
fi

"$ROOT/scripts/seed-projects.sh" >/dev/null

children=()
stop() { for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap stop EXIT
trap 'exit 130' INT TERM

# 2. One engine for every client.
"$ENGINE/.venv/bin/python" "$ROOT/scripts/engine-host.py" --port "$ENGINE_PORT" --projects-dir "$ROCKET_PROJECTS_DIR" &
children+=($!)
export ROCKET_ENGINE_URL="http://127.0.0.1:$ENGINE_PORT"
for _ in $(seq 1 120); do
  python3 -I -c "import urllib.request, sys; urllib.request.urlopen(sys.argv[1], timeout=2)" "$ROCKET_ENGINE_URL/health" \
    2>/dev/null && break
  kill -0 "${children[0]}" 2>/dev/null || { echo "The engine did not start." >&2; exit 1; }
  sleep 0.5
done

# 3. The model. Only Meta models run: the agent's config enables no other provider, and its calls go through the
# relay. A replay makes no model calls at all.
export ROCKET_MODEL="${ROCKET_MODEL:-meta/muse-spark-1.3}"
if [[ "$MODE" == replay ]]; then
  SAMPLE="$(ls "$ROOT"/docs/sample-runs/*/session.jsonl 2>/dev/null | head -1 || true)"
  SAMPLE="${ROCKET_REPLAY:-$SAMPLE}"
  [[ -f "$SAMPLE" ]] || { echo "No recorded session in docs/sample-runs/." >&2; exit 1; }
  REPLAY_PORT="${ROCKET_REPLAY_PORT:-8767}"
  python3 -I "$ROOT/rocket_fuel/evals/replay_server.py" "$SAMPLE" --port "$REPLAY_PORT" >/dev/null &
  children+=($!)
  export ROCKET_AGENT_URL="http://127.0.0.1:$REPLAY_PORT"
  echo "Replaying ${SAMPLE#"$ROOT"/}. Open a project: the assistant plays it back, marked REPLAY. No model is called."
else
  case "$ROCKET_MODEL" in
    meta/*) ;;
    *) echo "ROCKET_MODEL=$ROCKET_MODEL is not a Meta model. Use meta/muse-spark-1.3 in .env." >&2; exit 2 ;;
  esac
  RELAY_PORT="${ROCKET_META_RELAY_PORT:-8766}"
  mkdir -p "$ROOT/logs"
  python3 -I "$ROOT/rocket_fuel/scripts/meta-relay.py" --port "$RELAY_PORT" --log "$ROOT/logs/meta-calls.jsonl" \
    --upstream "${ROCKET_META_UPSTREAM:-https://api.meta.ai}" &
  children+=($!)
  export ROCKET_META_BASE_URL="http://127.0.0.1:$RELAY_PORT/v1"
  CREDENTIALS="${ROCKET_CREDENTIALS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/rocketide/credentials}"
  if [[ -z "${MODEL_API_KEY:-}" && ! -s "$CREDENTIALS" ]]; then
    echo "No Meta API key yet. Add yours in the app's assistant panel. The IDE and engine checks work without one."
    echo "To see the agent without a key: ./run.sh replay"
  fi
fi

# 4. The web app (and through it the agent), then the desktop window on the same server.
cd "$ROOT/UIUX"
node dist-server/serve.js &
children+=($!)
if [[ "$MODE" == desktop ]]; then
  [[ -f dist-electron/main.js ]] || { echo "No desktop build. Run ./install.sh without --no-desktop." >&2; exit 1; }
  for _ in $(seq 1 60); do
    python3 -I -c "import urllib.request, sys; urllib.request.urlopen(sys.argv[1], timeout=2)" \
      "http://127.0.0.1:$UI_PORT/api/status" 2>/dev/null && break
    sleep 0.5
  done
  # Electron opens a running server instead of starting its own, so both windows share one workspace and agent.
  VITE_DEV_SERVER_URL="http://127.0.0.1:$UI_PORT" npx electron . &
  children+=($!)
fi
wait -n
