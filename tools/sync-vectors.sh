#!/usr/bin/env bash
# Copies the canonical bridge vectors, the launcher's fixtures/bridge/*.json, into fixtures/bridge/,
# removing vectors the launcher no longer has; the launcher's README there is not copied. The
# launcher defaults to the sibling checkout that the tests' parity check compares against; pass
# another path as the only argument.
#
#   tools/sync-vectors.sh [launcher-repo]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
launcher=${1:-$root/../../Android/Launcher}
source=$launcher/fixtures/bridge

[ -d "$source" ] || { echo "no vectors at $source" >&2; exit 2; }
mkdir -p "$root/fixtures/bridge"
rsync -a --delete --exclude '.*' --include '*.json' --exclude '*' "$source/" "$root/fixtures/bridge/"
git -C "$root" status --short -- fixtures/bridge
