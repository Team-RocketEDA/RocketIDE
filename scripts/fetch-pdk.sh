#!/usr/bin/env bash
# Downloads the prebuilt open-source sky130A PDK, about 140 MB, with no account or key. Only the parts the demos
# use: common, primitives and HD cells, the same ones CI uses. Prints the folder it wrote on its last line.
#
#   scripts/fetch-pdk.sh [folder]     default ~/.local/share/pdk, which makes ~/.local/share/pdk/sky130A
set -euo pipefail

REVISION=792ef67037d74c8c51811eab3ce23cf793491296
BASE="https://github.com/fossi-foundation/ciel-releases/releases/download/sky130-$REVISION"
PARENT="${1:-$HOME/.local/share/pdk}"
DEST="$PARENT/sky130A"

if [[ -f "$DEST/.config/nodeinfo.json" ]]; then
  echo "$DEST"
  exit 0
fi
for tool in curl tar zstd; do
  command -v "$tool" >/dev/null || { echo "Missing $tool: install it from your package manager." >&2; exit 1; }
done

mkdir -p "$PARENT"
WORK="$(mktemp -d "$PARENT/.fetch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for part in common sky130_fd_pr sky130_fd_sc_hd; do
  echo "Downloading $part..." >&2
  curl -fL --retry 3 --progress-bar "$BASE/$part.tar.zst" | zstd -dc | tar -x -f - -C "$WORK" sky130A
done
[[ -f "$WORK/sky130A/.config/nodeinfo.json" ]] || { echo "The download has no sky130A/.config/nodeinfo.json." >&2; exit 1; }
# Only a finished download takes the real name, so an interrupted one is simply fetched again.
mv "$WORK/sky130A" "$DEST"
echo "$DEST"
