#!/bin/bash
# Builds a release binary and installs the shared Claude/Codex skill. Re-runnable.
# MCP registration is optional: wand setup --mcp.
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

echo "==> Installing shared skill"
SKILL_SHARE="$PREFIX/../share/wand/skills/wand"
mkdir -p "$SKILL_SHARE"
install -m 644 "$DIR/skills/wand/SKILL.md" "$SKILL_SHARE/SKILL.md"
install -m 644 "$DIR/THIRD_PARTY_NOTICES" "$PREFIX/../share/wand/THIRD_PARTY_NOTICES"
"$PREFIX/wand" setup

case ":$PATH:" in
  *":$PREFIX:"*) : ;;
  *) echo "==> NOTE: add $PREFIX to your PATH:  export PATH=\"$PREFIX:\$PATH\"" ;;
esac

echo ""
echo "Done. Boot a simulator, then try:"
echo "  wand info"
echo "  wand ui"
