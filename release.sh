#!/bin/bash
# Build a distributable Wand binary. Codesigns with a Developer ID and notarizes
# only when the right credentials are present; otherwise falls back to an ad-hoc
# signature (fine for local/Homebrew-from-source use). Honest about what it can do.
#
# Env for signing/notarization (all optional):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   AC_PROFILE="notarytool-profile"   # a stored `xcrun notarytool store-credentials` profile
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
VERSION="${1:-0.1.0}"
OUT="$DIR/dist"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> Building universal release binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/wand"
cp "$BIN" "$OUT/wand"
file "$OUT/wand"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "==> Codesigning with Developer ID: $DEVELOPER_ID"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$OUT/wand"
else
  echo "==> No DEVELOPER_ID set — applying ad-hoc signature (not notarizable)."
  codesign --force --sign - "$OUT/wand"
fi

ZIP="$OUT/wand-$VERSION-macos-universal.zip"
( cd "$OUT" && zip -q "wand-$VERSION-macos-universal.zip" wand )

if [[ -n "${DEVELOPER_ID:-}" && -n "${AC_PROFILE:-}" ]]; then
  echo "==> Notarizing (this uploads the binary to Apple)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$AC_PROFILE" --wait
  echo "    (CLI binaries can't be stapled; Gatekeeper verifies online on first run.)"
else
  echo "==> Skipping notarization — set DEVELOPER_ID and AC_PROFILE to enable."
  echo "    Honest note: without an Apple Developer ID + notarytool profile, the"
  echo "    binary is only ad-hoc signed. Distribute via 'brew install' (builds"
  echo "    from source) for a frictionless, trusted install."
fi

shasum -a 256 "$ZIP" | tee "$OUT/SHA256SUMS"
echo "==> Done: $ZIP"
