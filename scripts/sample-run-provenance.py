"""Judges one recorded run and writes its README: scripts/record-sample-runs.sh calls this after each run.

Exits 1 if the run must not be kept: unfinished, no model calls, a failed call, a reply naming a model that isn't
Muse, or the API key anywhere in the files.
Usage: sample-run-provenance.py <run-dir> <name> <project> <prompt> <finished 0|1>
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARTS = ["rocket-engine", "rocket_fuel", "UIUX", "Demos/albert-chip-demo", "Demos/photonic_matmul", "Demos/waveform-generator"]


def commit(path):
    return subprocess.run(["git", "-C", str(path), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()


def main():
    run, name, project, prompt, finished = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
    log = run / "meta-calls.jsonl"
    records = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    replies = [r for r in records if r["event"] == "response"]
    models = sorted({r["model"] for r in replies if r.get("model")})
    header = json.loads((run / "session.jsonl").read_text().splitlines()[0]) if (run / "session.jsonl").exists() else {}

    problems = []
    if not finished or not header.get("complete"):
        problems.append("the session did not finish")
    if not replies:
        problems.append("no model calls were logged")
    failed = [r for r in replies if r["status"] >= 400]
    if failed:
        problems.append(f"{len(failed)} calls failed, first with HTTP {failed[0]['status']}")
    if not models or any("muse" not in m.lower() for m in models):
        problems.append(f"models reported by the API: {models or 'none'}")
    key = os.environ.get("MODEL_API_KEY", "")
    if key and any(key in p.read_text(errors="replace") for p in run.rglob("*") if p.is_file()):
        problems.append("the API key appears in the files")
    if problems:
        print("    " + "; ".join(problems), file=sys.stderr)
        return 1

    tokens_in = sum(r.get("tokens_in") or 0 for r in replies)
    tokens_out = sum(r.get("tokens_out") or 0 for r in replies)
    seconds = sum(r.get("seconds") or 0 for r in replies)
    upstream = os.environ.get("ROCKET_META_UPSTREAM", "https://api.meta.ai")
    real = upstream == "https://api.meta.ai"
    pins = "\n".join(f"| `{part}` | `{commit(ROOT / part)}` |" for part in PARTS)
    what = "A real session of the RocketIDE agent on Muse Spark" if real else f"A TEST against a stand-in at {upstream}, not a real model"
    (run / "README.md").write_text(f"""# Sample run: {name}

{what}, recorded by `scripts/record-sample-runs.sh`. Play it back with
`ROCKET_REPLAY=docs/sample-runs/{name}/session.jsonl ./run.sh replay`. No model is called during a replay.

| | |
|---|---|
| Prompt | {prompt} |
| Project | `{project}` |
| Recorded | {header.get("recorded_at")} |
| Model API | {upstream} |
| Model requested | `{header.get("model")}` |
| Model reported by the API | {", ".join(f"`{m}`" for m in models)} |
| Model API calls | {len(replies)}, all successful |
| Tokens | {tokens_in} in, {tokens_out} out |
| Time in model calls | {seconds:.1f} s |
| Agent | `{header.get("agent")}`, opencode {header.get("opencode")}; approvals answered "once" by the recorder |

## Files

- `session.jsonl`: the agent's full event stream, with local paths rewritten.
- `meta-calls.jsonl`: one line per request and response from `rocket_fuel/scripts/meta-relay.py`. The model name in
  each response line comes from the API's own reply. Keys and prompts are never logged.
- `outputs/results/`: what the engine wrote, if the run produced results. Its measurements decide each check.
- `outputs/commits.txt`, `outputs/uncommitted.diff`: the project's history and any uncommitted changes after the run.

## Commits used

| Part | Commit |
|---|---|
| `RocketIDE` | `{commit(ROOT)}` |
{pins}
""")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
