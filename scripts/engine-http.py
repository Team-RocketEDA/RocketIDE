"""Serves the engine's HTTP adapter for headless requests. Loopback only: the adapter refuses anything else.

Run through ./run.sh --engine-http <port>, or from rocket-engine/: uv run python ../scripts/engine-http.py
POST a JSON envelope to / : {"project_id": "...", "operation": "list_job_kinds", "arguments": {}}
"""

import argparse

from rocket_engine.adapters.http import serve_http
from rocket_engine.composition import Engine


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--project", default="headless", help="project id this server answers for")
    args = parser.parse_args()
    serve_http(Engine(args.project, actor="http"), host="127.0.0.1", port=args.port, project_id=args.project)


if __name__ == "__main__":
    main()
