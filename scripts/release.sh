#!/usr/bin/env bash
# Release Snap through app-updates (CONTRACT.md): every check.sh gate, a fresh release bundle,
# then app-updates/tools/publish.sh. Usage: scripts/release.sh [--notes <file.md>] [--dry-run <dir>]
#
# --dry-run <dir> is passed to publish.sh, which then writes into <dir> and publishes nothing, and
# makes tools/notarize.sh print its commands instead of submitting.
#
# With a Developer ID Application certificate in the keychain and the notarytool keychain profile
# sdusteric-notary, the bundle is notarized and stapled before it is published (see
# app-updates/docs/notarization.md).
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
# Hardened runtime, entitlements, one team for every Mach-O.
"$ROOT/scripts/check-signing.sh" "$APP"

# Notarize and staple when the bundle is signed with Developer ID (tools/notarize.sh). With the
# Apple Development fallback it warns and the release goes on. --dry-run prints the notarization
# commands and does not submit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/snap-release.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"' EXIT
FINAL_ZIP="$WORK/final.zip"
nargs=(--bundle "$APP" --final-zip "$FINAL_ZIP")
[ -z "$DRY_RUN" ] || nargs+=(--dry-run)
rc=0
"$APP_UPDATES/tools/notarize.sh" "${nargs[@]}" || rc=$?

args=(--app snap --bundle "$APP")
[ -z "$NOTES" ] || args+=(--notes "$NOTES")
[ -z "$DRY_RUN" ] || args+=(--dry-run "$DRY_RUN")
case "$rc" in
  0) args+=(--zip "$FINAL_ZIP") ;; # the stapled app, zipped after stapling: the Sparkle signature covers it
  10) ;;                           # not notarized (fallback certificate or dry run): publish.sh zips the bundle
  *) exit "$rc" ;;
esac
"$PUBLISH" "${args[@]}"
