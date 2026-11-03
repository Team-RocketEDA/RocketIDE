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

You need `git`, Node 20.12 or newer, [`uv`](https://docs.astral.sh/uv/) and `ngspice`.

```sh
git clone --recurse-submodules https://github.com/Team-RocketEDA/RocketIDE.git
cd RocketIDE
./install.sh --no-desktop     # add --photonic for optical runs; drop --no-desktop for the desktop app
./run.sh                      # http://localhost:5173
```

Or in Docker, which also brings the open-source EDA tools:

```sh
git submodule update --init --recursive
docker build -t rocketide .
docker run --rm -p 127.0.0.1:5173:5173 -v rocketide-projects:/opt/rocketide/projects rocketide
```

To check the assembled IDE, `scripts/smoke.py` starts it and drives projects, checks, plot data and the engine's APIs.
`--agent` also sends a prompt to the model. A check whose tool isn't installed reports SKIP, not a pass.

### Choosing the model

`install.sh` creates `.env`. The default is a free model that needs no key, and shares one quota per machine. For Muse
Spark, set `ROCKET_MODEL=meta/muse-spark-1.3` and `MODEL_API_KEY`.

## How it fits together

```text
browser or Electron window
        |  HTTP, same origin
UI server (UIUX/server) ---- projects/<name>   one git repo per project
        |            \
        | stdio MCP   \ starts and proxies, adding its password
        v              v
Rocket Engine  <---- opencode with Rocket Fuel (agent + plugin + prompts)
        |     stdio MCP
        v
ngspice, iverilog, SAX, Magic, KLayout, LibreLane ...
```

The browser never talks to the engine or the agent directly. The UI server starts both, so passwords and model keys
never reach browser code. It binds to `127.0.0.1` and has no login, so don't expose its port beyond your machine.

The engine's HTTP API is optional, for headless requests from the same machine or container:

```sh
./run.sh --engine-http 8765
curl -s localhost:8765 -H 'Content-Type: application/json' \
  -d '{"project_id": "headless", "operation": "list_job_kinds", "arguments": {}}'
```

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

## What runs where

| Check | Needs |
|---|---|
| Op-amp template, waveform RC filter | `ngspice` |
| MobileLLM `mac_unit` testbench | `iverilog` |
| Photonic mesh | `./install.sh --photonic` |
| sky130A DRC, LVS and PDK simulation | a PDK; see the engine's `scripts/install.sh --pdk-only` |

A check whose tool or PDK is missing reports `NOT_RUN` with the reason. It is never counted as a pass.

Each demo's own README has its results and how to reproduce them, and some flows need tools beyond these.
