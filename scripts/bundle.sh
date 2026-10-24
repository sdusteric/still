#!/usr/bin/env bash
# Build, sign and optionally install Snap.app. Usage: scripts/bundle.sh [--release] [--install]
# Never launches the app. Output: build/bundle/Snap.app
#
# The app is always built with `swift build -c release`; --release is accepted so callers can
# spell it out.
#
# Env (all optional):
#   SNAP_SCRATCH     SwiftPM scratch path (default <repo>/.build). Agents building in parallel pass
#                    their own.
#   SNAP_BUNDLE_BIN  use this binary instead of running swift build
#   SNAP_BUNDLE_ID   CFBundleIdentifier (default dev.sdusteric.snap)
#   SIGN_ID          signing identity SHA-1 (default: the Apple Development cert)
#   INSTALL_DIR      install target for --install (default: $HOME/Applications)
#
# --install copies the bundle to ~/Applications with ditto. Agents and acceptance never use it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

INSTALL=0
for a in "$@"; do
  case "$a" in
    --release) ;;
    --install) INSTALL=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

BUNDLE_ID="${SNAP_BUNDLE_ID:-dev.sdusteric.snap}"
# SHA-1 of the cert, not the name: several certs can share the CN and some are expired.
SIGN_ID="${SIGN_ID:-1EDDD87FAAACC222585E8C76E983DB798EC38331}"
SCRATCH="${SNAP_SCRATCH:-$REPO/.build}"
OUT="$REPO/build/bundle/Snap.app"

VERSION="$(tr -d '[:space:]' <"$REPO/VERSION")"
[ -n "$VERSION" ] || { echo "VERSION file is empty" >&2; exit 1; }
BUILD="$(date +%Y%m%d%H%M)"

# Check the signing identity before spending time on a build.
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  echo "signing identity not valid; renew the Apple Development certificate in Xcode" >&2
  exit 1
fi

if [ -n "${SNAP_BUNDLE_BIN:-}" ]; then
  BIN="$SNAP_BUNDLE_BIN"
else
  caffeinate -i swift build -c release --product Snap --package-path "$REPO" --scratch-path "$SCRATCH"
  BIN="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path)/Snap"
fi
[ -x "$BIN" ] || { echo "missing binary $BIN" >&2; exit 1; }

# Only ever delete the bundle dir inside this repo's build dir.
case "$OUT" in */build/bundle/Snap.app) ;; *) echo "refusing odd output path $OUT" >&2; exit 1 ;; esac
[ -d "$OUT" ] && rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Snap"

sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|" -e "s|@VERSION@|$VERSION|" -e "s|@BUILD@|$BUILD|" \
  "$REPO/resources/Info.plist.in" >"$OUT/Contents/Info.plist"
printf 'APPL????' >"$OUT/Contents/PkgInfo"
plutil -lint "$OUT/Contents/Info.plist"

# Icon: resources/AppIcon.png if present, else generated.
TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/snap-bundle.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"' EXIT
PNG="$REPO/resources/AppIcon.png"
if [ ! -f "$PNG" ]; then
  swift "$SCRIPT_DIR/make-icon.swift" "$WORK/icon-1024.png"
  PNG="$WORK/icon-1024.png"
fi
SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$PNG" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$PNG" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT/Contents/Resources/AppIcon.icns"

# Sign with the Apple Development cert: no hardened runtime, no entitlements, no --deep.
# --timestamp=none needs no network. The designated requirement keys on the bundle id and the
# cert, so the Screen Recording grant survives rebuilds (design section 13).
codesign --force --sign "$SIGN_ID" --timestamp=none "$OUT"
codesign --verify --strict --verbose=2 "$OUT"

if [ "$INSTALL" = 1 ]; then
  DEST_DIR="${INSTALL_DIR:-$HOME/Applications}"
  DEST="$DEST_DIR/Snap.app"
  mkdir -p "$DEST_DIR"
  case "$DEST" in */Snap.app) ;; *) echo "refusing odd install path $DEST" >&2; exit 1 ;; esac
  [ -d "$DEST" ] && rm -rf "$DEST"
  ditto "$OUT" "$DEST"
  echo "installed $DEST"
else
  echo "built $OUT"
fi
