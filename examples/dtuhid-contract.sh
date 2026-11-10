#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/wand-dtuhid-contract.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
xcrun clang -fobjc-arc -fmodules -mmacosx-version-min=13.0 \
  -framework Foundation -framework CoreGraphics -framework IOSurface \
  "$ROOT/examples/dtuhid-contract.m" -o "$OUT/contract"
"$OUT/contract"
