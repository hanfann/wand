#!/bin/bash
# Wand end-to-end regression suite against the native SwiftUI showcase.
# Every complex gesture is verified purely through the accessibility tree
# (the app mirrors the recognized gesture into its #status element).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WAND="${WAND:-$ROOT/.build/debug/wand}"
BUNDLE="com.wand.showcase.native"

xcrun simctl terminate booted "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl launch booted "$BUNDLE" >/dev/null 2>&1
sleep 2
"$WAND" ui >/dev/null 2>&1   # warm the app + accessibility before the first gesture

pass=0; fail=0
# Read #status from the FULL tree — the showcase's status label can sit off-screen
# (negative y), which the on-screen `ui` omits.
status() { "$WAND" ui full 2>/dev/null | sed -n 's/.*"\(.*\)" #status.*/\1/p'; }
check() {
  local name="$1" expect="$2"; shift 2
  "$@" >/dev/null 2>&1; sleep 0.5
  local got; got="$(status)"
  if [[ "$got" == *"$expect"* ]]; then
    echo "  PASS  $name  ->  $got"; pass=$((pass+1))
  else
    echo "  FAIL  $name  ->  '$got' (wanted *$expect*)"; fail=$((fail+1))
  fi
}

echo "Wand E2E — native showcase"
check "tap"        "tap:"        "$WAND" tap "#tapButton"
check "long-press" "longpress"   "$WAND" longpress "#longPressBox"
check "pinch"      "pinch"       "$WAND" pinch "#pinchBox" 1.8
check "rotate"     "rotat"       "$WAND" rotate "#rotateBox" 0.9
check "drag-drop"  "drop:zoneB"  "$WAND" dragdrop "#dragHandle" "#zoneB"
check "type"       "typed:"      "$WAND" typein "#textInput" hello

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
