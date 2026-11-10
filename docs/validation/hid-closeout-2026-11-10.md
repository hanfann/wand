# Xcode 27 HID failures closed — 10 November 2026

The two input failures from the earlier deep audit are fixed and verified on
Xcode 27.2: native Watch Crown and iOS gesture delivery. This qualifies the tested
40mm SE / watchOS 27.2 and iPhone 17 Pro / iOS 27.2, not every Apple runtime.

## Change and cause

The legacy SimulatorKit Indigo path could acknowledge events that never reached
an app. Wand now selects DTUHID by the host Xcode version, with **one persistent
host connection** for touch, multitouch, keyboard and Crown. Older Xcodes retain
Indigo. No guest helper, SDK lookup or helper compilation is needed.

[Meta idb's transport documentation](https://github.com/facebook/idb/blob/main/FBSimulatorControl/README.md#hid-indigohid-and-dtuhid)
provided the modern protocol and simulator XPC connection recipe. Attribution
and its MIT license are in `THIRD_PARTY_NOTICES`, also installed with the binary.
An important local finding: the separate `.hid.scroll` endpoint accepted Crown
samples without scrolling Settings. Sending the same real Crown scroll payload
through `.hid.digitizer` produced movement. Wand uses that shared connection;
it does **not** translate Crown commands into swipes.

The connection must answer a harmless liveness probe before receiving input.
Only probes retry; input never replays automatically. Interrupted connections
refuse further input until the selected daemon is restarted. Send waits are
bounded, and asynchronous errors remain visible after settling. Multitouch and
keyboard loops stop on their first delivery failure. The simulator-free contract
test covers wire types, phase values, two contacts, Crown routing and interruption.

Accessibility now initializes on demand, so daemon startup does not require an
eager AX snapshot before `info`, `launch` or `stop` can run. This does not put a
hard deadline around every private accessibility call.

## Verification

| Check | Result |
|---|---|
| Settings tap/back transitions | **100/100 PASS**, screenshot content compared after each action |
| Watch tap latency, including settling | median **1,427 ms**, p95 **1,581 ms**, under the 2-second gate |
| Native Crown | **PASS**: returns to top after touch drag; scrolls down; returns to top again |
| Device Hub visibility | **PASS**: observed native Crown move Settings from its top rows to Bluetooth / Display & Brightness / App View in the existing window |
| Watch batch validation / stop-on-error | **PASS**: no unintended tap after invalid later step or failed assertion |
| Guest HID helper processes | **0**, verified for the selected watch |
| iOS native fixture | **6/6 PASS**: tap, long press, pinch, rotate, drag/drop to zone B, exact `typed:hello` |
| Unit tests | **27 PASS**, no failures |
| DTUHID contract | **PASS**: unsigned wire types, phases, multitouch, keyboard, Crown routing, no sends after interruption |
| Client / MCP regressions | **PASS**: no lost-reply replay, framing, invalid arguments, compact/full catalogs, persistent requests |
| Installation | release and installed binary hashes match; shared Claude/Codex skill validated and updated |

The final text oracle exposed an ordinary keyboard preference: autocapitalization
changed `hello` into `Hello`. The fixture now explicitly disables capitalization
and autocorrect; the assertion still requires the exact text. Observation polls
for up to 5 seconds across keyboard transitions, without repeating the input.
Real app fields continue to apply their own keyboard behavior.

The 100-action watch run used the HID-final binary; the installed build then
removed eager AX initialization. HID code is identical between these artifacts.
The final iOS suite used the installed build. Both hashes are recorded below.

## Limits and setup failures

Cold iOS boot/install/launch was intermittently unresponsive during substantial
host load (one-minute load exceeded 400). Earlier retest attempts failed setup
before any gesture ran; those logs are retained. The disposable phone was shut
down, then booted using the existing Device Hub window. Once the fixture was
ready, the final six-outcome run passed. Do not read this input sign-off as a
claim that every CoreSimulator cold start or private AX request is bounded or
reliable. Older runtimes, iPad, folding displays and nondefault orientation were
not requalified.

Only one test simulator ran at a time. The stateful production QA watch was not
booted or modified. The existing disposable watch's app data and Keychain were
backed up before boot and preserved. Testing used Settings, not Belly.

## Reproduce and evidence

Use explicit disposable device IDs; these suites do not reset a device:

```sh
swift test
bash examples/dtuhid-contract.sh
python3 examples/transport-smoke.py .build/release/wand
python3 examples/protocol-regressions.py .build/release/wand
# Watch: Settings root visible, selected disposable already booted.
WAND_SMOKE_CYCLES=50 swift examples/watch/touch-smoke.swift WATCH_UDID /absolute/path/to/wand /tmp/watch-evidence
# iPhone: native fixture built/installed, selected disposable already booted.
WAND_UDID=IPHONE_UDID WAND=/absolute/path/to/wand bash examples/native/e2e.sh
```

Evidence: [watch results](hid-closeout-2026-11-10/watch-final.txt),
[latency samples](hid-closeout-2026-11-10/watch-latency.json),
[iOS results](hid-closeout-2026-11-10/ios-final.txt),
[unit results](hid-closeout-2026-11-10/unit-final.txt),
[wire contract](hid-closeout-2026-11-10/contract-final.txt),
[artifact hashes](hid-closeout-2026-11-10/environment.json).
Four Watch screenshots and one iPhone screenshot are retained alongside these
logs. Intermediate captures, probe binaries, reference downloads and the native
fixture build directory are removed after verification. The task-created iPhone
is deleted after shutdown; the pre-existing disposable watch is preserved.

Changes are installed locally. They have not been committed or pushed in this
follow-up.
