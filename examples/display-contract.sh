#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp /tmp/wand-display-contract.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
clang -fobjc-arc -fmodules -framework Foundation -framework CoreGraphics -framework IOSurface "$ROOT/examples/display-contract.m" -o "$BIN"
"$BIN"
