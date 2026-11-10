#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp /tmp/wand-gesture-contract.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
xcrun clang -fobjc-arc -fmodules -I "$ROOT/Sources/WandEngine/include" \
  -framework Foundation -framework AppKit -framework CoreGraphics \
  -framework CoreImage -framework ImageIO -framework IOSurface -framework Vision \
  "$ROOT/examples/gesture-contract.m" "$ROOT/Sources/WandEngine/WNDAccessibility.m" \
  "$ROOT/Sources/WandEngine/WNDDTUHID.m" "$ROOT/Sources/WandEngine/WNDDisplayInfo.m" -o "$BIN"
"$BIN"
