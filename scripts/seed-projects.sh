#!/usr/bin/env bash
# Copies each demo in Demos/ into projects/ as its own git repo, so the IDE and the agent edit and commit
# there and the submodules stay pinned and clean. An existing project is left alone, so work isn't lost;
# pass --reset to replace them all from Demos/.
# integration/overlays/<demo>/ adds what the IDE needs to open and check a demo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS="${ROCKET_PROJECTS_DIR:-$ROOT/projects}"
OVERLAYS="$ROOT/integration/overlays"
mkdir -p "$PROJECTS"

for demo in "$ROOT"/Demos/*/; do
  name="$(basename "$demo")"
  dest="$PROJECTS/$name"
  if [[ -e "$dest" ]]; then
    [[ "${1:-}" == "--reset" ]] || { echo "$name: kept"; continue; }
    rm -rf "$dest"
  fi
  mkdir -p "$dest"
  tar --exclude=.git -C "$demo" -cf - . | tar -xf - -C "$dest"
  if [[ -d "$OVERLAYS/$name" ]]; then
    tar --exclude=constraints.append.yaml -C "$OVERLAYS/$name" -cf - . | tar -xf - -C "$dest"
    if [[ -f "$OVERLAYS/$name/constraints.append.yaml" ]]; then
      cat "$OVERLAYS/$name/constraints.append.yaml" >> "$dest/constraints.yaml"
    fi
  fi
  git -C "$dest" init -q -b main
  git -C "$dest" add -A
  git -C "$dest" -c user.name="RocketEDA IDE" -c user.email=ide@rocketeda.local commit -q -m "Import $name"
  echo "$name: ready"
done
