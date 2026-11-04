# RocketIDE

An AI chip-design IDE. You describe what you want in the assistant, and an agent edits the design and runs real EDA
tools. Pass or fail comes only from the engine's measurements, never from the agent's own claims.

| Part | Folder | What it does |
|---|---|---|
| [Rocket IDE](https://github.com/Team-RocketEDA/UIUX) | `UIUX/` | The workbench: projects, editor, assistant, schematic, layout, plots, verification |
| [Rocket Engine](https://github.com/Team-RocketEDA/rocket-engine) | `rocket-engine/` | Runs the tools (ngspice, Icarus, SAX, Magic, KLayout, LibreLane and more) and records evidence |
| [Rocket Fuel](https://github.com/Team-RocketEDA/rocket_fuel) | `rocket_fuel/` | The agent harness: protected paths, repair limit, tool allowlist, audit log |

## Demo projects

Each one opens in the IDE as its own project.

| Project | Folder | What it shows |
|---|---|---|
| Photonic matrix multiplier | `Demos/photonic_matmul/` | A 4x4 Reck mesh of tunable MZIs on CORNERSTONE Si340 |
| Waveform generator | `Demos/waveform-generator/` | Phase accumulator, R-2R DAC and RC filter on sky130A |
| MobileLLM decoder chip | `Demos/albert-chip-demo/` | A transformer decoder in RTL, with a first block through place-and-route |

## Quick start

You need `git`, Node 20.12 or newer, [`uv`](https://docs.astral.sh/uv/), and a PDK for the engine to register
(sky130A at `~/.local/share/pdk/sky130A`, or set `PDK_SOURCE`). The engine's provisioner installs the EDA tools.

```sh
git clone --recurse-submodules https://github.com/Team-RocketEDA/RocketIDE.git
cd RocketIDE
./install.sh --no-desktop     # add --photonic for optical runs; drop --no-desktop for the desktop app
./run.sh                      # http://localhost:5173; ./run.sh desktop also opens the desktop window
```

Setup is the engine's own, unchanged:

1. `install.sh` runs `rocket-engine/scripts/install.sh --install`: the engine's Python environment, the PDK it
   registers, and its pinned toolchain from `scripts/provision_toolchain.sh --install`.
2. `run.sh` puts the provisioned tools on `PATH` from `provision_toolchain.sh --print-path`.
3. It starts one engine (`scripts/engine-host.py`, on `127.0.0.1:8765`).
4. The web app, the desktop window and the agent all use that engine.

Or in Docker, set up the way the engine's own image is, with the PDK on a volume:

```sh
git submodule update --init --recursive
docker build -t rocketide .
docker run --rm -p 127.0.0.1:5173:5173 -v /path/to/sky130A:/pdk:ro \
  -v rocketide-store:/stores/rocketeda -v rocketide-projects:/opt/rocketide/projects rocketide
```

To check the assembled IDE, `scripts/smoke.py` starts it and drives projects, checks, plot data and the engine's APIs.
`--agent` also sends a prompt to the model. A check whose tool isn't installed reports SKIP, not a pass.

### Choosing the model

`install.sh` creates `.env`. The default is a free model that needs no key, and shares one quota per machine. For Muse
Spark, set `ROCKET_MODEL=meta/muse-spark-1.3` and `MODEL_API_KEY`.

## How it fits together

```text
browser            Electron window
      \              /   HTTP, same origin
UI server (UIUX/server) ---- projects/<name>   one git repo per project
      |                 \  starts and proxies, adding its password
      |                  v
      |            opencode with Rocket Fuel (agent + plugin + prompts)
      |  HTTP              |  MCP over HTTP
      v                    v
Rocket Engine, one per project (scripts/engine-host.py, 127.0.0.1:8765) <---- headless scripts
      |
ngspice, iverilog, SAX, Magic, KLayout, LibreLane ...  (from the engine's provisioner)
```

The engine is the project's engine for everyone: a human working in the IDE, the agent working alongside them, and
scripts. The agent gets the engine's own MCP tools, and Run checks goes through the same engine handlers, so both
see each other's runs and evidence. Calls into one project take turns.

The browser never talks to the engine or the agent directly. The UI server reaches both, so passwords and model keys
never reach browser code. It binds to `127.0.0.1` and has no login, so don't expose its port beyond your machine. The
engine listens on loopback only, with no auth, and refuses requests from other sites.

Headless requests from the same machine or container:

```sh
# Through the engine handlers the IDE uses (run, fetch if deferred, record the evidence)
curl -s localhost:8765/projects/waveform-generator/call -H 'Content-Type: application/json' \
  -d '{"operation": "get_check_results", "arguments": {}}'
# The engine's own HTTP API, on the same engine
curl -s localhost:8765/projects/waveform-generator/api/ -H 'Content-Type: application/json' \
  -d '{"project_id": "waveform-generator", "operation": "list_job_kinds", "arguments": {}}'
```

Other MCP clients can attach at `http://127.0.0.1:8765/projects/<name>/mcp`.

## How the repo is organised

`Demos/` and the three parts are git submodules, each pinned to a tested commit. The IDE never edits them: `install.sh`
copies each demo to `projects/` as its own git repo, and the IDE and agent work there. `scripts/seed-projects.sh --reset`
restores all of them from `Demos/`, and discards any work in those copies.

`integration/overlays/` holds what a demo needs to open in the IDE, such as a `constraints.yaml` saying what "Run checks"
does. It is applied to the copy, not the submodule.

To move a part to the latest commit of its branch:

```sh
git submodule update --remote rocket-engine && git add rocket-engine && scripts/smoke.py
```

## Builds and releases

`.github/workflows/build.yml` builds the Docker image and desktop app on a clean machine and runs the photonic and demo
checks. It needs a `SUBMODULES_TOKEN` secret with read access to the submodule repos. Pushing a `v*` tag publishes a
release with the archive from `./install.sh --package`, once those jobs pass.

## What runs where

| Check | Needs |
|---|---|
| Op-amp template, waveform RC filter | `ngspice` (provisioned) |
| MobileLLM `mac_unit` testbench | `iverilog` (provisioned) |
| Photonic mesh | `./install.sh --photonic` |
| sky130A DRC, LVS and PDK simulation | the PDK registered at install (`/pdk` in Docker) |

A check whose tool or PDK is missing reports `NOT_RUN` with the reason. It is never counted as a pass.

Each demo's own README has its results and how to reproduce them, and some flows need tools beyond these.
