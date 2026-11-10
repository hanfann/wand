#!/bin/bash
# Wand end-to-end regression suite against the native SwiftUI showcase.
# Every complex gesture is verified purely through the accessibility tree
# (the app mirrors the recognized gesture into its #status element).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WAND="${WAND:-$ROOT/.build/debug/wand}"
BUNDLE="com.wand.showcase.native"
UDID="${WAND_UDID:?Set WAND_UDID to a disposable iOS simulator}"

"$WAND" --udid "$UDID" terminate "$BUNDLE" >/dev/null 2>&1 || true
launch_args=("$BUNDLE")
if [[ "${WAND_NATIVE_ORIENTATION:-portrait}" == "landscape" ]]; then launch_args+=("--landscape"); fi
if ! "$WAND" --udid "$UDID" launch "${launch_args[@]}"; then
  echo "FAIL: could not launch the native fixture" >&2
  exit 1
fi
if ! "$WAND" --udid "$UDID" wait "#tapButton" "${WAND_READY_TIMEOUT_MS:-30000}"; then
  echo "FAIL: native fixture did not expose its controls; no gestures attempted" >&2
  exit 1
fi

if [[ "${WAND_NATIVE_ORIENTATION:-portrait}" == "landscape" ]]; then
  "$WAND" --udid "$UDID" wait "#landscapeReady" 10000 || exit 1
fi

pass=0; fail=0
# Read #status from the FULL tree — the showcase's status label can sit off-screen
# (negative y), which the on-screen `ui` omits.
status() { "$WAND" --udid "$UDID" ui full 2>/dev/null | sed -n 's/.*"\(.*\)" #status.*/\1/p'; }
matches() {
  local name="$1" got="$2" expect="$3"
  case "$name" in
    type|unicode|punctuation|clear) [[ "$got" == "$expect" ]] ;;
    tap) [[ "$got" == "tap:1" ]] ;;
    long-press|drag-drop) [[ "$got" == "$expect" ]] ;;
    pinch) [[ "$got" =~ ^pinched:([0-9.]+)$ ]] && awk "BEGIN { exit !(${BASH_REMATCH[1]} > 1.4 && ${BASH_REMATCH[1]} < 2.2) }" ;;
    rotate) [[ "$got" =~ ^rotated:([0-9]+)$ ]] && (( BASH_REMATCH[1] > 30 && BASH_REMATCH[1] < 75 )) ;;
    *) [[ "$got" == *"$expect"* ]] ;;
  esac
}
capture_case() {
  if [[ -n "${WAND_EVIDENCE_DIR:-}" ]]; then
    mkdir -p "$WAND_EVIDENCE_DIR"
    "$WAND" --udid "$UDID" screenshot "$WAND_EVIDENCE_DIR/$1.png" >/dev/null || true
    "$WAND" --udid "$UDID" ui full > "$WAND_EVIDENCE_DIR/$1.ui.txt" 2>&1 || true
  fi
}
check() {
  local name="$1" expect="$2"; shift 2
  if ! "$@"; then
    echo "  FAIL  $name (input command failed)"; fail=$((fail+1))
    capture_case "$name"
    # A partial gesture can leave a contact down. Later cases would measure
    # contaminated state; preserve the failure and stop without replaying input.
    exit 1
  fi
  local got="" deadline=$((SECONDS + ${WAND_OUTCOME_TIMEOUT_SECONDS:-5}))
  # Keyboard/navigation transitions can briefly hide the status AX node.
  # Poll observations only; never replay a gesture to make the test pass.
  while (( SECONDS <= deadline )); do
    got="$(status)"
    matches "$name" "$got" "$expect" && break
    sleep 0.1
  done
  if matches "$name" "$got" "$expect"; then
    echo "  PASS  $name  ->  $got"; pass=$((pass+1))
  else
    echo "  FAIL  $name  ->  '$got' (wanted $expect)"; fail=$((fail+1))
  fi
  capture_case "$name"
}

echo "Wand E2E — native showcase"
check "tap"        "tap:"        "$WAND" tap "#tapButton"
if [[ "${WAND_NATIVE_ORIENTATION:-portrait}" != "landscape" ]]; then
check "long-press" "longpress"   "$WAND" longpress "#longPressBox"
check "pinch"      "pinch"       "$WAND" pinch "#pinchBox" 1.8
check "rotate"     "rotat"       "$WAND" rotate "#rotateBox" 0.9
check "drag-drop"  "drop:zoneB"  "$WAND" dragdrop "#dragHandle" "#zoneB"
fi
check "type"       "typed:hello"      "$WAND" typein "#textInput" hello

# Reset fixture focus/layout before testing direct AX text entry. A keyboard can
# occlude the field; setvalue must not tap and hide its target before resolving it.
"$WAND" --udid "$UDID" terminate "$BUNDLE" >/dev/null 2>&1 || true
"$WAND" --udid "$UDID" launch "${launch_args[@]}" >/dev/null || exit 1
"$WAND" --udid "$UDID" wait "#textInput" "${WAND_READY_TIMEOUT_MS:-30000}" >/dev/null || exit 1
check "unicode" "typed:héllo🌱" "$WAND" setvalue "#textInput" "héllo🌱"

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
