#!/bin/bash
# Wand installer. Builds a release binary, puts it on PATH, installs the Claude
# Code skill, and registers the MCP server. Re-runnable.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PREFIX="${PREFIX:-$HOME/.local/bin}"

echo "==> Building release binary..."
swift build -c release
BIN="$DIR/.build/release/wand"

echo "==> Installing to $PREFIX/wand"
mkdir -p "$PREFIX"
install "$BIN" "$PREFIX/wand"

echo "==> Installing skill + registering MCP"
"$PREFIX/wand" setup || true

case ":$PATH:" in
  *":$PREFIX:"*) : ;;
  *) echo "==> NOTE: add $PREFIX to your PATH:  export PATH=\"$PREFIX:\$PATH\"" ;;
esac

echo ""
echo "Done. Boot a simulator, then try:"
echo "  wand info"
echo "  wand ui"
