#!/usr/bin/env bash
# Release Snap through app-updates (CONTRACT.md): every check.sh gate, a fresh release bundle,
# then app-updates/tools/publish.sh. Usage: scripts/release.sh [--notes <file.md>] [--dry-run <dir>]
#
# --dry-run <dir> is passed to publish.sh, which then writes into <dir> and publishes nothing.
#
# Env (all optional):
#   SNAP_SCRATCH  SwiftPM scratch path, passed to check.sh and bundle.sh
#   APP_UPDATES   the app-updates checkout (default: ../app-updates next to this repo)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_UPDATES="${APP_UPDATES:-$(cd "$ROOT/.." && pwd)/app-updates}"
PUBLISH="$APP_UPDATES/tools/publish.sh"
APP="$ROOT/build/bundle/Snap.app"

NOTES=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes)
      [ $# -ge 2 ] || { echo "--notes needs a file" >&2; exit 2; }
      NOTES="$2"; shift 2 ;;
    --dry-run)
      [ $# -ge 2 ] || { echo "--dry-run needs a directory" >&2; exit 2; }
      DRY_RUN="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; echo "usage: scripts/release.sh [--notes <file.md>] [--dry-run <dir>]" >&2; exit 2 ;;
  esac
done
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "notes file not found: $NOTES" >&2; exit 2; }
[ -x "$PUBLISH" ] || { echo "missing $PUBLISH" >&2; exit 1; }

"$ROOT/scripts/check.sh"
# A fresh bundle after the gates, so its CFBundleVersion is the newest build time.
"$ROOT/scripts/bundle.sh" --release
codesign --verify --deep --strict "$APP"

args=(--app snap --bundle "$APP")
[ -z "$NOTES" ] || args+=(--notes "$NOTES")
[ -z "$DRY_RUN" ] || args+=(--dry-run "$DRY_RUN")
"$PUBLISH" "${args[@]}"
