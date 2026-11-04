#!/usr/bin/env python3
"""End-to-end check of the assembled IDE: starts it the way ./run.sh does, with a throwaway projects folder, and
drives the same HTTP API the browser uses. A check whose EDA tool isn't installed is reported as SKIP, not passed.

Usage: scripts/smoke.py [--port 5199] [--agent] [--strict]
--strict fails instead of skipping when a tool is missing, so a clean machine can't pass by not running anything.
--agent also sends one prompt to Muse Spark, which needs your Meta API key, added in the app or in .env.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEMOS = ["albert-chip-demo"]
results = []


def report(status, name, detail=""):
    results.append(status)
    print(f"{status:5} {name}{' - ' + detail if detail else ''}", flush=True)


def check(name, ok, detail=""):
    report("PASS" if ok else "FAIL", name, detail)
    return ok


class Api:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"

    def call(self, method, path, body=None, headers=None, timeout=330):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers or {})
        if data:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def json(self, method, path, body=None):
        status, raw = self.call(method, path, body)
        return status, json.loads(raw) if raw else None


def wait_for_agent(api, timeout=90):
    deadline = time.time() + timeout
    state = {}
    while time.time() < deadline:
        _, project = api.json("GET", "/api/project")
        state = (project or {}).get("agent", {})
        if state.get("state") != "starting":
            break
        time.sleep(1)
    return state


def run_checks(api, name, expect):
    """Opens a project, runs its checks and asserts the verdict; expect(verdict) returns a problem or None."""
    status, _ = api.json("POST", f"/api/projects/{name}/open")
    if not check(f"{name}: opens", status == 200, f"HTTP {status}"):
        return None
    agent = wait_for_agent(api)
    check(f"{name}: agent starts", agent.get("state") == "ready", agent.get("error", ""))
    status, files = api.json("GET", "/api/project/files")
    check(f"{name}: lists its files", status == 200 and len(files) > 3, f"{len(files or [])} files")
    status, result = api.json("POST", "/api/project/checks/run")
    verdict = (result or {}).get("verdict") or {}
    check_records(api, name)
    if verdict.get("status") in ("NOT_RUN", "UNSUPPORTED"):
        report("SKIP", f"{name}: checks", f"{verdict['status']}: {str(verdict.get('reason'))[:110]}")
        return None
    problem = expect(verdict) if verdict else f"HTTP {status}: {str(result)[:160]}"
    check(f"{name}: checks", problem is None, problem or verdict.get("status", ""))
    if verdict.get("measurements"):
        # The Overview pairs each check with the measurement named by its metric; an unmatched check never shows a result.
        _, project = api.json("GET", "/api/project")
        metrics = [c.get("metric") for c in ((project or {}).get("constraints") or {}).get("checks") or []]
        unmatched = sorted(set(metrics) - set(measured(verdict)))
        check(f"{name}: every check is measured", bool(metrics) and not unmatched, ", ".join(unmatched)[:160])
    return result


def check_records(api, name):
    """Every run record must have a verdict: the UI's pages read it from each one."""
    _, evidence = api.json("GET", "/api/project/checks")
    runs = evidence if isinstance(evidence, list) else (evidence or {}).get("runs", [])
    check(f"{name}: run records are all valid", bool(runs) and all(run.get("verdict") for run in runs), f"{len(runs)} runs")


def measured(verdict):
    return {m["name"]: m["value"] for m in verdict.get("measurements", [])}


def expect_opamp(verdict):
    gain = measured(verdict).get("dc_gain_db")
    if verdict.get("status") != "FAIL" or gain is None or abs(gain - 55.73) > 0.05:
        return f"expected FAIL at 55.73 dB, got {verdict.get('status')} {gain}"


def expect_measured(metric, value, tolerance, status):
    """What a lesson's checks should report: the simulator's number, and the verdict from it."""
    def expect(verdict):
        got = measured(verdict).get(metric)
        if verdict.get("status") != status or got is None or abs(got - value) > tolerance:
            return f"expected {status} at {metric}={value}, got {verdict.get('status')} {got}"
    return expect


def check_lesson(api, lesson, start, file, old, new, solved):
    """A lesson starts out failing, and the change it teaches makes it pass, all on the real engine."""
    status, _ = api.json("POST", "/api/projects", {"name": lesson, "template": lesson})
    check(f"{lesson}: can be started", status == 201, f"HTTP {status}")
    if not run_checks(api, lesson, start):
        return
    _, project = api.json("GET", "/api/project")
    check(f"{lesson}: opens as a lesson", (project or {}).get("lesson") is True)
    status, content = api.json("GET", f"/api/project/file?path={file}")
    text = (content or {}).get("content", "")
    check(f"{lesson}: has the value to change", old in text, old)
    status, _ = api.json("PUT", "/api/project/file", {"path": file, "content": text.replace(old, new)})
    check(f"{lesson}: the change saves", status == 200, f"HTTP {status}")
    status, result = api.json("POST", "/api/project/checks/run")
    verdict = (result or {}).get("verdict") or {}
    problem = solved(verdict)
    check(f"{lesson}: the change makes it pass", problem is None, problem or verdict.get("status", ""))


def expect_pass(verdict):
    if verdict.get("status") != "PASS":
        return f"expected PASS, got {verdict.get('status')}: {str(verdict.get('reason'))[:120]}"


def check_plot_data(api, name, analysis, needle):
    _, evidence = api.json("GET", "/api/project/checks")
    runs = evidence if isinstance(evidence, list) else (evidence or {}).get("runs", [])
    data = [d for run in runs for d in run.get("datasets") or [] if d.get("analysis") == analysis]
    if not check(f"{name}: run keeps {analysis} plot data", bool(data), f"{len(runs)} runs"):
        return
    status, raw = api.call("GET", "/api/project/raw?path=" + urllib.parse.quote(data[0]["path"]))
    check(f"{name}: plot data is served", status == 200 and needle.encode() in raw)


def check_agent_prompt(api):
    auth = {"Content-Type": "application/json"}
    status, raw = api.call("POST", "/agent/session", {}, auth)
    if not check("agent: session through the proxy", status == 200, f"HTTP {status}"):
        return
    session = json.loads(raw)["id"]
    prompt = {"parts": [{"type": "text", "text": "Call engine_list_job_kinds, then reply with only the word READY."}],
              "agent": "rocket-auto"}
    status, raw = api.call("POST", f"/agent/session/{session}/message", prompt, auth, timeout=240)
    text = raw.decode(errors="replace")
    check("agent: a real model answered", status == 200 and "READY" in text, f"HTTP {status}: {text[:200]}")
    status, raw = api.call("GET", f"/agent/session/{session}/message")
    check("agent: it reached the engine", b"engine_list_job_kinds" in raw and b"run_spice" in raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=5199)
    parser.add_argument("--agent", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    projects = Path(tempfile.mkdtemp(prefix="rocketide-smoke-"))
    engine_port = args.port + 1
    env = {**os.environ, "ROCKET_PROJECTS_DIR": str(projects), "ROCKET_UI_PORT": str(args.port),
           "ROCKET_ENGINE_PORT": str(engine_port)}
    server = subprocess.Popen([ROOT / "run.sh"], env=env, start_new_session=True)
    engine = f"http://127.0.0.1:{engine_port}"
    api = Api(args.port)
    try:
        for _ in range(120):
            try:
                status, _ = api.call("GET", "/api/status", timeout=3)
                if status == 200:
                    break
            except OSError:
                time.sleep(0.5)
        else:
            report("FAIL", "IDE starts")
            return 1

        status, html = api.call("GET", "/")
        check("UI is served", status == 200 and b'id="root"' in html)
        status, info = api.json("GET", "/api/status")
        check("engine and agent are found in the bundle",
              info["engineFound"] and info["fuelHome"] == str(ROOT / "rocket_fuel")
              and info["engineHome"] == str(ROOT / "rocket-engine"))
        print("      tools:", " ".join(sorted(tool for tool, found in info["tools"].items() if found)) or "none")
        status, listed = api.json("GET", "/api/projects")
        names = {project["name"] for project in listed}
        check("the demo is listed", names >= set(DEMOS), ", ".join(sorted(names)))
        status, _ = api.call("GET", "/api/status", headers={"Host": "evil.example"})
        check("other sites are refused", status == 403, f"HTTP {status}")

        status, _ = api.json("POST", "/api/projects", {"name": "smoke-opamp", "template": "opamp-engine"})
        check("a project can be created from a template", status == 201, f"HTTP {status}")
        if run_checks(api, "smoke-opamp", expect_opamp):
            check_plot_data(api, "smoke-opamp", "ac", "AC Analysis")
        if args.agent:
            check_agent_prompt(api)
            config = json.loads((projects / "smoke-opamp" / ".opencode" / "opencode.json").read_text())
            mcp = config["mcp"]["engine"]
            check("agent: attached to the shared engine", mcp.get("type") == "remote"
                  and mcp.get("url") == f"{engine}/projects/smoke-opamp/mcp", json.dumps(mcp)[:120])

        run_checks(api, "albert-chip-demo", expect_pass)
        check_lesson(api, "lesson-1-rc-filter", expect_measured("corner_low_khz", 0.159, 0.01, "FAIL"),
                     "design/rc_filter.cir", ".param R1=10k", ".param R1=1k",
                     expect_measured("corner_low_khz", 1.59, 0.05, "PASS"))
        check_lesson(api, "lesson-2-amplifier", expect_measured("gain_db", 6.09, 0.2, "FAIL"),
                     "design/amplifier.cir", ".param RL=5k", ".param RL=30k",
                     expect_measured("gain_db", 21.05, 0.2, "PASS"))
        api.json("POST", "/api/project/close")

        # The IDE's Run checks went to the engine run.sh started, so that engine remembers them.
        with urllib.request.urlopen(f"{engine}/health", timeout=10) as response:
            health = json.load(response)
        check("one engine serves every project", health["ok"] and set(DEMOS) <= set(health["projects"]),
              ", ".join(health["projects"]))
        envelope = {"project_id": "albert-chip-demo", "operation": "get_check_results", "arguments": {}}
        request = urllib.request.Request(f"{engine}/projects/albert-chip-demo/api/", json.dumps(envelope).encode(),
                                         {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            answer = json.load(response)
        latest = answer.get("checks", {}).get("run_hdl_test", {})
        check("headless: the engine's HTTP API sees the IDE's run", latest.get("status") == "PASS",
              json.dumps(latest)[:120])
        request = urllib.request.Request(f"{engine}/projects/albert-chip-demo/api/", json.dumps(envelope).encode(),
                                         {"Content-Type": "application/json", "Origin": "http://evil.example"})
        try:
            urllib.request.urlopen(request, timeout=10)
            refused = False
        except urllib.error.HTTPError as error:
            refused = error.code == 403
        check("the engine refuses other sites", refused)

        dirty = subprocess.run(["git", "-C", str(ROOT), "submodule", "foreach", "--quiet", "git status --porcelain"],
                               capture_output=True, text=True).stdout.strip()
        if (ROOT / ".git").exists():
            check("running it left the submodules clean", not dirty, dirty[:200])
    finally:
        try:
            os.killpg(server.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        server.wait(timeout=10)
        shutil.rmtree(projects, ignore_errors=True)

    print(f"\n{results.count('PASS')} passed, {results.count('FAIL')} failed, {results.count('SKIP')} skipped")
    return 1 if "FAIL" in results or (args.strict and "SKIP" in results) else 0


if __name__ == "__main__":
    sys.exit(main())
