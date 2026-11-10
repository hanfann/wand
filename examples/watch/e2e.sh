#!/bin/bash
# Wand watchOS end-to-end regression — scroll, Digital Crown, and the fail-loud
# guard. Uses the always-present Settings app (no custom app to install) and
# asserts via OCR that the visible list actually moved. Requires a booted watch.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WAND="${WAND:-$ROOT/.build/debug/wand}"
BUNDLE="com.apple.NanoSettings"

# Explicit opt-in avoids accidentally driving an unrelated/production watch.
UDID="${WAND_WATCH_UDID:-}"
if [ -z "$UDID" ]; then
  echo "SKIP: set WAND_WATCH_UDID to a booted disposable watch"
  exit 0
fi

# Reset to a known top-of-list, then read the first non-clock label.
relaunch() {
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1
  for _ in $(seq 1 20); do "$WAND" --udid "$UDID" see 2>/dev/null | grep -q "Notifications" && break; sleep 1; done
}
topLabel() {
  "$WAND" --udid "$UDID" see 2>/dev/null \
    | grep -vE '"[0-9]+:[0-9]+"|text regions|"Settings"' | head -1 \
    | sed -E 's/.*"([^"]*)".*/\1/'
}

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "Wand watchOS E2E — $UDID"

# 1. scroll down moves the list off the top.
relaunch; before="$(topLabel)"
"$WAND" --udid "$UDID" scroll down 3 >/dev/null 2>&1; sleep 0.6; after="$(topLabel)"
[ -n "$before" ] && [ "$before" != "$after" ] && ok "scroll down  ($before -> $after)" || bad "scroll down  ($before -> $after)"

# 2. scroll up returns toward the top.
"$WAND" --udid "$UDID" scroll up 5 >/dev/null 2>&1; sleep 0.6; back="$(topLabel)"
[ "$back" == "Notifications" ] && ok "scroll up returns to top  ($back)" || bad "scroll up returns to top  ($back)"

# 3. Digital Crown down moves the list (watchOS-only).
relaunch; before="$(topLabel)"
"$WAND" --udid "$UDID" crown down 6 >/dev/null 2>&1; sleep 0.8; after="$(topLabel)"
[ -n "$before" ] && [ "$before" != "$after" ] && ok "crown down  ($before -> $after)" || bad "crown down  ($before -> $after)"

# 4. Crown up returns toward the top.
"$WAND" --udid "$UDID" crown up 10 >/dev/null 2>&1; sleep 0.8; back="$(topLabel)"
[ "$back" == "Notifications" ] && ok "crown up returns to top  ($back)" || bad "crown up returns to top  ($back)"

# 5. Fail-loud guard: an unsupported build must refuse (non-zero), not act silently.
WAND_FORCE_UNSUPPORTED=1 "$WAND" --udid "$UDID" stop >/dev/null 2>&1; sleep 1
if WAND_FORCE_UNSUPPORTED=1 "$WAND" --udid "$UDID" crown down 2 >/dev/null 2>&1; then
  bad "fail-loud guard (command succeeded under forced-unsupported)"
else
  ok "fail-loud guard refuses unsupported build (exit != 0)"
fi
"$WAND" --udid "$UDID" stop >/dev/null 2>&1   # clear the forced-unsupported daemon

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
