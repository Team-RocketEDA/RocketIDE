#!/usr/bin/env python3
"""One Rocket Engine for every RocketIDE client.

run.sh starts this once. It holds one engine per project, and every client reaches that same engine:

  POST /projects/<id>/call   the web and desktop app (Run checks, the run console), and headless scripts
  /projects/<id>/mcp         the agent, over MCP (streamable HTTP), with the same tools as the engine's
                             stdio server
  /projects/<id>/api/        the engine's own HTTP adapter (POST / envelopes, GET /health)
  POST /catalog/call         queries that need no project, such as list_job_kinds
  GET  /modules/<name>       whether a Python package imports in the engine's environment
  GET  /health

The engine's own MCP handlers do the work, so argument checks, targets from constraints.yaml, source
confinement and the evidence files are exactly what its stdio server does. Calls into one project run one at
a time. Run it with the engine's interpreter (rocket-engine/.venv/bin/python). Loopback only, no auth: the
same trust boundary as the engine's HTTP adapter.
"""

import argparse
import asyncio
import contextlib
import importlib.util
import json
import os
import re
import sys
import threading
import urllib.parse
from pathlib import Path

import anyio
import uvicorn
from mcp.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import CallToolRequestParams
from starlette.applications import Starlette
from starlette.responses import JSONResponse

from rocket_engine.adapters.http import HttpTransport, check_loopback_host, create_app, trust_banner
from rocket_engine.adapters.mcp.server import load_constraints, make_handlers, write_evidence
from rocket_engine.composition import Engine
from rocket_engine.interfaces.vocabulary import OPERATIONS

LOOPBACK = {"127.0.0.1", "localhost", "::1", "[::1]"}
PROJECT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ACTOR = "rocketide"


class Project:
    """One project's engine and the handlers every client shares."""

    def __init__(self, project_id, folder):
        self.id = project_id
        self.folder = folder
        self.lock = threading.Lock()
        self._stamp = self._constraints_stamp()
        constraints = load_constraints(folder) if folder else None
        self.engine = Engine(project_id, actor=ACTOR, constraints=constraints)
        self.list_tools, self._call = make_handlers(
            lambda _pid: self.engine, project_scope=project_id,
            project_dir=str(folder) if folder else None,
        )
        self.mcp = None
        self.api = None

    def _constraints_stamp(self):
        path = self.folder / "constraints.yaml" if self.folder else None
        return path.stat().st_mtime_ns if path and path.is_file() else None

    def _refresh_constraints(self):
        # The engine reads its targets once, when it is built; a stdio server is rebuilt per session. This one
        # lives as long as RocketIDE, so a saved constraints.yaml has to reach it. Rebuilding the engine instead
        # would drop the runs it remembers.
        stamp = self._constraints_stamp()
        if self.folder and stamp != self._stamp:
            targets = load_constraints(self.folder)
            self.engine._constraints = dict(targets) if targets is not None else None
            self._stamp = stamp

    def invoke(self, name, arguments):
        """One tool call through the engine's MCP handlers. Returns (failed, result, CallToolResult)."""
        with self.lock:
            self._refresh_constraints()
            result = asyncio.run(self._call(None, CallToolRequestParams(name=name, arguments=arguments)))
        return result.is_error, json.loads(result.content[0].text), result

    def call(self, name, arguments):
        """What `--call` does: run one operation, fetch it if it was deferred, record a finished run."""
        failed, body, _ = self.invoke(name, dict(arguments))
        if not failed and name in OPERATIONS and "run_id" in body and "verdict" not in body:
            failed, body, _ = self.invoke("run_job", {"run_id": body["run_id"]})
            if not failed and "run_id" in body:
                failed, body, _ = self.invoke("get_job_status", {"run_id": body["run_id"]})
        if (not failed and name in OPERATIONS and self.folder and "run_id" in body
                and body.get("state") == "completed"):
            with self.lock:
                write_evidence(str(self.folder), self.engine, [body], arguments)
        return failed, body


class SharedTransport(HttpTransport):
    """The engine's HTTP adapter, taking turns with the other clients of this project."""

    def __init__(self, project):
        super().__init__(project.engine, project_id=project.id)
        self._project = project

    def handle(self, text):
        with self._project.lock:
            return super().handle(text)


class Host:
    def __init__(self, projects_dir):
        self.projects_dir = Path(projects_dir).resolve()
        self.projects = {}
        self._guard = threading.Lock()
        self._start_lock = asyncio.Lock()
        self.tasks = None

    def project(self, project_id):
        if project_id == "catalog":
            folder = None
        else:
            if not PROJECT_ID.match(project_id):
                raise LookupError(f"Not a project name: {project_id}")
            folder = (self.projects_dir / project_id).resolve()
            if folder.parent != self.projects_dir or not folder.is_dir():
                raise LookupError(f"No project {project_id} in {self.projects_dir}")
        with self._guard:
            if project_id not in self.projects:
                self.projects[project_id] = Project(project_id, folder)
            return self.projects[project_id]

    async def mcp_for(self, project):
        async with self._start_lock:
            if project.mcp is None:
                async def call_tool(_ctx, params):
                    return (await anyio.to_thread.run_sync(project.invoke, params.name, params.arguments or {}))[2]

                server = Server("rocket-engine", on_list_tools=project.list_tools, on_call_tool=call_tool)
                manager = StreamableHTTPSessionManager(
                    app=server, json_response=True, stateless=True,
                    security_settings=TransportSecuritySettings(
                        enable_dns_rebinding_protection=True,
                        allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*"],
                        allowed_origins=["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"],
                    ),
                )

                async def keep(*, task_status=anyio.TASK_STATUS_IGNORED):
                    async with manager.run():
                        task_status.started()
                        await anyio.sleep_forever()

                await self.tasks.start(keep)
                project.mcp = manager
        return project.mcp


def _loopback(value):
    if not value:
        return True
    host = urllib.parse.urlsplit(value if "//" in value else f"//{value}").hostname or ""
    return host in LOOPBACK or f"[{host}]" in LOOPBACK


def build_app(host):
    async def json_body(receive):
        chunks = []
        while True:
            message = await receive()
            chunks.append(message.get("body", b""))
            if not message.get("more_body"):
                break
        return json.loads(b"".join(chunks) or b"{}")

    async def app(scope, receive, send):
        if scope["type"] == "lifespan":
            return await lifespan(scope, receive, send)
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        # A page on another site must not drive the engine through the user's browser.
        if not _loopback(headers.get("host")) or not _loopback(headers.get("origin")):
            return await JSONResponse({"error": "cross_origin_denied"}, status_code=403)(scope, receive, send)
        path, method = scope["path"], scope["method"]
        parts = [p for p in path.split("/") if p]

        if path == "/health":
            body = {"ok": True, "projects": sorted(host.projects), "projects_dir": str(host.projects_dir)}
            return await JSONResponse(body)(scope, receive, send)
        if len(parts) == 2 and parts[0] == "modules" and method == "GET":
            name = parts[1]
            try:
                found = bool(re.fullmatch(r"[A-Za-z_][\w.]*", name)) and importlib.util.find_spec(name) is not None
            except (ImportError, ValueError):
                found = False
            return await JSONResponse({"module": name, "importable": found})(scope, receive, send)

        if parts[:1] == ["catalog"]:
            parts = ["projects", "catalog", *parts[1:]]
        if len(parts) < 3 or parts[0] != "projects":
            return await JSONResponse({"error": "not_found"}, status_code=404)(scope, receive, send)
        try:
            project = await anyio.to_thread.run_sync(host.project, parts[1])
        except LookupError as exc:
            return await JSONResponse({"error": "unknown_project", "message": str(exc)}, status_code=404)(
                scope, receive, send)

        if parts[2] == "call" and len(parts) == 3 and method == "POST":
            try:
                request = await json_body(receive)
                operation = request["operation"]
                arguments = request.get("arguments") or {}
            except (ValueError, KeyError, TypeError):
                return await JSONResponse(
                    {"error": "invalid_command", "message": "Send {operation, arguments}."}, status_code=400,
                )(scope, receive, send)
            failed, body = await anyio.to_thread.run_sync(project.call, operation, arguments)
            return await JSONResponse(body, status_code=422 if failed else 200)(scope, receive, send)
        if parts[2] == "mcp" and project.folder is not None:
            manager = await host.mcp_for(project)
            return await manager.handle_request(scope, receive, send)
        if parts[2] == "api" and project.folder is not None:
            if project.api is None:
                project.api = create_app(SharedTransport(project))
            prefix = f"/projects/{project.id}/api"
            inner = dict(scope, path=path[len(prefix):] or "/", root_path=scope.get("root_path", "") + prefix)
            return await project.api(inner, receive, send)
        return await JSONResponse({"error": "not_found"}, status_code=404)(scope, receive, send)

    @contextlib.asynccontextmanager
    async def running(_app):
        async with anyio.create_task_group() as tasks:
            host.tasks = tasks
            yield
            tasks.cancel_scope.cancel()

    lifespan = Starlette(lifespan=running).router.lifespan
    return app


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("ROCKET_ENGINE_PORT", 8765)))
    parser.add_argument("--projects-dir", default=os.environ.get("ROCKET_PROJECTS_DIR", "projects"))
    args = parser.parse_args(argv)
    check_loopback_host(args.host)
    host = Host(args.projects_dir)
    print(trust_banner(args.host, args.port), file=sys.stderr)
    print(f"Rocket Engine for {host.projects_dir} on http://{args.host}:{args.port}", file=sys.stderr, flush=True)
    uvicorn.run(build_app(host), host=args.host, port=args.port, log_level="warning", lifespan="on")


if __name__ == "__main__":
    main()
