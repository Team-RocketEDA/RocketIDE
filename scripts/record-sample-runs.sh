#!/usr/bin/env bash
# Records real Muse Spark sessions into docs/sample-runs/<name>/, so people without a key can see them with
# ./run.sh replay. Needs MODEL_API_KEY in .env. Each run gets:
#
#   session.jsonl     the agent's full event stream, what ./run.sh replay plays back
#   meta-calls.jsonl  every Meta Model API call: model the API reported, tokens, timing, request id
#   outputs/          the engine's results and the project's commits after the run
#   README.md         how it was made: prompt, models, date, and the commit of every part
#
# It uses fresh copies of the projects and its own engine and relay, so it leaves projects/ alone. A run with any
# failed call or a model that isn't Muse is rejected and not kept.
#
#   scripts/record-sample-runs.sh [name...]     default: all of 1-opamp-to-spec 2-waveform-check 3-mac-unit-check
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then
  EXPORTED="$(export -p)"
  set -a; source .env; set +a
  eval "$EXPORTED"
fi
UPSTREAM="${ROCKET_META_UPSTREAM:-https://api.meta.ai}"
OUT="${ROCKET_SAMPLE_RUNS_DIR:-$ROOT/docs/sample-runs}"
[[ -n "${MODEL_API_KEY:-}" ]] || { echo "Set MODEL_API_KEY in .env first." >&2; exit 1; }
export ROCKET_MODEL="${ROCKET_MODEL:-meta/muse-spark-1.3}"

ENGINE="$ROOT/rocket-engine"
export ROCKET_ENGINE_HOME="$ENGINE" ROCKET_FUEL_HOME="$ROOT/rocket_fuel" UV_NO_SYNC=1
if paths="$(bash "$ENGINE/scripts/provision_toolchain.sh" --print-path 2>/dev/null)"; then eval "$paths"; fi

WORK="$(mktemp -d)"
children=()
cleanup() { for pid in "${children[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

export ROCKET_PROJECTS_DIR="$WORK/projects"
scripts/seed-projects.sh >/dev/null
cp -r rocket_fuel/examples/opamp-engine "$ROCKET_PROJECTS_DIR/opamp"
git -C "$ROCKET_PROJECTS_DIR/opamp" init -q -b main
git -C "$ROCKET_PROJECTS_DIR/opamp" add -A
git -C "$ROCKET_PROJECTS_DIR/opamp" -c user.name="RocketEDA IDE" -c user.email=ide@rocketeda.local commit -q -m "Create project from opamp-engine"

ENGINE_PORT="$(free_port)"
"$ENGINE/.venv/bin/python" scripts/engine-host.py --port "$ENGINE_PORT" --projects-dir "$ROCKET_PROJECTS_DIR" >"$WORK/engine.log" 2>&1 &
children+=($!)
export ROCKET_ENGINE_URL="http://127.0.0.1:$ENGINE_PORT"
for _ in $(seq 1 120); do
  python3 -I -c "import urllib.request, sys; urllib.request.urlopen(sys.argv[1], timeout=2)" "$ROCKET_ENGINE_URL/health" 2>/dev/null && break
  sleep 0.5
done

record() {
  local name="$1" project="$2" prompt="$3"
  local tmp="$WORK/run-$name" dir="$ROCKET_PROJECTS_DIR/$project" port pid
  mkdir -p "$tmp/outputs"
  port="$(free_port)"
  python3 -I rocket_fuel/scripts/meta-relay.py --port "$port" --upstream "$UPSTREAM" --log "$tmp/meta-calls.jsonl" &
  pid=$!
  children+=("$pid")
  echo "==> $name"
  local ok=1
  ROCKET_META_BASE_URL="http://127.0.0.1:$port/v1" python3 -I rocket_fuel/evals/record_session.py \
    --project "$dir" --agent rocket-approval --approve --prompt "$prompt" --out "$tmp/session.jsonl" || ok=0
  kill "$pid" 2>/dev/null || true
  [[ -d "$dir/results" ]] && cp -r "$dir/results" "$tmp/outputs/results"
  git -C "$dir" log --format='%h %ad %s' --date=iso > "$tmp/outputs/commits.txt"
  git -C "$dir" status --short --untracked-files=no > "$tmp/outputs/uncommitted.txt"
  git -C "$dir" diff > "$tmp/outputs/uncommitted.diff"
  if python3 -I scripts/sample-run-provenance.py "$tmp" "$name" "$project" "$prompt" "$ok"; then
    rm -rf "${OUT:?}/$name"
    mkdir -p "$OUT"
    mv "$tmp" "$OUT/$name"
    echo "    kept $OUT/$name"
  else
    echo "    rejected, not kept" >&2
    return 1
  fi
}

declare -i failed=0
wanted=("$@")
[[ ${#wanted[@]} -gt 0 ]] || wanted=(1-opamp-to-spec 2-waveform-check 3-mac-unit-check)
for name in "${wanted[@]}"; do
  case "$name" in
    1-opamp-to-spec) record "$name" opamp "Bring this op-amp to spec." || failed+=1 ;;
    2-waveform-check) record "$name" waveform-generator \
      "Run this project's checks with the engine and tell me whether the design meets its targets. Cite the measured values." || failed+=1 ;;
    3-mac-unit-check) record "$name" albert-chip-demo \
      "Run this project's checks with the engine, then explain what the mac_unit testbench proves and what it doesn't." || failed+=1 ;;
    *) echo "Unknown run: $name" >&2; failed+=1 ;;
  esac
done
exit "$failed"
