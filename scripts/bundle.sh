#!/usr/bin/env bash
# Build, sign and optionally install Still.app. Usage: scripts/bundle.sh [--release] [--install]
# Never launches the app. Output: build/bundle/Still.app
#
# The app is always built with `swift build -c release`; --release is accepted so callers can
# spell it out.
#
# Env (all optional):
#   SNAP_SCRATCH     SwiftPM scratch path (default <repo>/.build). Agents building in parallel pass
#                    their own.
#   SNAP_BUNDLE_BIN  use this binary instead of running swift build (Sparkle.framework is taken
#                    from the same directory)
#   SNAP_BUNDLE_ID   CFBundleIdentifier (default dev.sdusteric.snap)
#   SIGN_ID          signing identity SHA-1 or name (default: the Developer ID Application cert of
#                    team 8N9KUZLT8N when the keychain has one, else the Apple Development cert)
#   SNAP_BUNDLE_OUT  output bundle path, must end in bundle/Still.app (default <repo>/build/bundle/Still.app)
#   INSTALL_DIR      install target for --install (default: /Applications)
#
# --install copies the bundle to /Applications with ditto. Agents and acceptance never use it.
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
# Signing identity. SIGN_ID (a SHA-1 or a name) overrides. Otherwise: the Developer ID Application
# certificate of team 8N9KUZLT8N when it is in the keychain, else the Apple Development
# certificate. Picked by SHA-1, not name: several certs can share the CN and some are expired.
TEAM_ID=8N9KUZLT8N
APPLE_DEV_SHA=1EDDD87FAAACC222585E8C76E983DB798EC38331
IDENTITIES="$(security find-identity -v -p codesigning)"
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(awk -v team="($TEAM_ID)" '/"Developer ID Application: / && index($0, team) { print $2; exit }' <<<"$IDENTITIES")"
  SIGN_ID="${SIGN_ID:-$APPLE_DEV_SHA}"
fi
SCRATCH="${SNAP_SCRATCH:-$REPO/.build}"
OUT="${SNAP_BUNDLE_OUT:-$REPO/build/bundle/Still.app}"

VERSION="$(tr -d '[:space:]' <"$REPO/VERSION")"
[ -n "$VERSION" ] || { echo "VERSION file is empty" >&2; exit 1; }
# CFBundleVersion is the UTC build time, so every release sorts after the one before it.
BUILD="$(date -u +%Y%m%d%H%M)"

# Check the signing identity before spending time on a build.
SIGN_LINE="$(grep -F -- "$SIGN_ID" <<<"$IDENTITIES" | head -n 1 || true)"
if [ -z "$SIGN_LINE" ]; then
  echo "signing identity $SIGN_ID is not valid; renew the Apple Development certificate in Xcode" >&2
  exit 1
fi
# A secure timestamp needs the network and Apple's server; notarization requires it. The Apple
# Development fallback skips it so a build works offline.
case "$SIGN_LINE" in
  *'"Developer ID Application: '*) TIMESTAMP=--timestamp ;;
  *) TIMESTAMP=--timestamp=none ;;
esac
echo "signing with:${SIGN_LINE#*)}"

if [ -n "${SNAP_BUNDLE_BIN:-}" ]; then
  BIN="$SNAP_BUNDLE_BIN"
else
  caffeinate -i swift build -c release --product Snap --package-path "$REPO" --scratch-path "$SCRATCH"
  BIN="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path)/Snap"
fi
[ -x "$BIN" ] || { echo "missing binary $BIN" >&2; exit 1; }

# Only ever delete a bundle dir named bundle/Still.app (the repo's build dir, or SNAP_BUNDLE_OUT).
case "$OUT" in */bundle/Still.app) ;; *) echo "refusing odd output path $OUT" >&2; exit 1 ;; esac
[ -d "$OUT" ] && rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Snap"

# Sparkle (app-updates CONTRACT.md): SwiftPM puts the framework next to the binary. ditto keeps
# the Versions symlinks. The executable finds it through @executable_path/../Frameworks.
SPARKLE_SRC="$(dirname "$BIN")/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || { echo "missing $SPARKLE_SRC" >&2; exit 1; }
mkdir -p "$OUT/Contents/Frameworks"
ditto "$SPARKLE_SRC" "$OUT/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$OUT/Contents/MacOS/Snap" | grep -q 'path @executable_path/../Frameworks '; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$OUT/Contents/MacOS/Snap"
fi

sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|" -e "s|@VERSION@|$VERSION|" -e "s|@BUILD@|$BUILD|" \
  "$REPO/resources/Info.plist.in" >"$OUT/Contents/Info.plist"
# The snap:// scheme belongs to the installed bundle id only (shelf design, section 11).
if [ "$BUNDLE_ID" != dev.sdusteric.snap ]; then
  plutil -remove CFBundleURLTypes "$OUT/Contents/Info.plist"
fi
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

# Everything is signed with the hardened runtime and the same identity, inside out, never with
# --deep. Sparkle's parts first, as Sparkle documents: its helpers keep their own signing and
# Downloader.xpc keeps its entitlements.
sign() { codesign --force --sign "$SIGN_ID" "$TIMESTAMP" --options runtime "$@"; }
SPARKLE="$OUT/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"

# Then the app, with its entitlements (resources/Snap.entitlements). The designated requirement
# keys on the bundle id and the certificate, so permission grants survive rebuilds with the same
# certificate. They reset once when the certificate changes.
sign --entitlements "$REPO/resources/Snap.entitlements" "$OUT"
codesign --verify --deep --strict --verbose=2 "$OUT"

if [ "$INSTALL" = 1 ]; then
  DEST_DIR="${INSTALL_DIR:-/Applications}"
  DEST="$DEST_DIR/Still.app"
  mkdir -p "$DEST_DIR"
  case "$DEST" in */Still.app) ;; *) echo "refusing odd install path $DEST" >&2; exit 1 ;; esac
  [ -d "$DEST" ] && rm -rf "$DEST"
  ditto "$OUT" "$DEST"
  echo "installed $DEST"
else
  echo "built $OUT"
fi
