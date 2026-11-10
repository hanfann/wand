# Reliability and resource review — 10 November 2026

Wand now isolates accessibility calls in a persistent worker, keeps input and stop
usable after AX/OCR stalls, handles MCP cancellation, and uses active display
geometry for iPad landscape input and upright screenshots. A focused test found
that `setvalue`'s preliminary tap could hide the target behind the keyboard; AX
now sets the value directly. No guest HID helper is needed.

Environment: Apple M4 (10 cores), 24 GiB, macOS 27.2, Xcode 27.2. Local runtime
coverage is iOS/watchOS 27.2. Use the [predeclared acceptance criteria](../performance.md)
and the [evidence directory](reliability-2026-11-10/); successful dispatch is not
counted as a successful app action.

## Results

| Gate | Observed result |
|---|---|
| Unit tests | 41 passed, including worker pipes, deadlines, cleanup and OCR selection |
| HID wire contract | Pass: types, phases, multitouch, keyboard, native Crown, interruption |
| Display contract | Pass: all four transforms; valid, malformed, inactive and ambiguous reports |
| Lifecycle | Pass: startup lock deadline, kill unready owned child, worker/startup parent death |
| MCP cancellation | Pass: active socket released under 500 ms, queued input skipped, next request healthy |
| Transport | Pass: fragmented Unicode, partial EOF, no lost-reply replay, persistent requests |
| Compact catalog | 502 bytes versus 7,142 bytes; 93% less serialized catalog, not an exact token count |
| Watch AX fault injection | Frozen worker fails in 5.013 s; next tap 427 ms, screenshot 105 ms, stop 15 ms |
| Native Crown | 100 actual down/up transitions passed on the 40mm watch; screenshot comparisons |
| iPad landscape | Seven of seven gesture/text outcomes passed, including Unicode; upright 2316×1512 screenshots |
| Memory, daemon + AX worker | 1,000 warm reads: +0.297 MiB; idle CPU 0% |
| Warm CLI / 128 KB reply p95 | 26.30 / 29.33 ms, both below 50 ms |
| Warm info / AX / 20-ping batch p95 | 28.08 / 33.97 / 26.46 ms |
| Watch screenshot p95 | 38.53 ms, below 100 ms |
| Fast OCR, watch Settings | Fresh ~201 ms; cached median 28.46 ms |
| OCR accuracy corpus | **Failed overall gate**: fast 29/32 exact labels with correct centers; accurate 0/32 due to deadlines |

Timing/memory and the 100-Crown run precede the final display/setvalue patches;
those changes are separately exercised by final live tests. Do not describe the
whole table as one immutable-binary run. Raw samples include maxima and failures.

The final watch retest caught a batch timing failure after individual navigation
and Crown passed. The watch settling floor was raised from 650 ms to 1 s; the
2 s observed tap p95 budget remains unchanged. A hosted CI setup attempt timed
out in initial `simctl list` before any UI tests; its cold discovery allowance
was raised to 120 s without relaxing warm performance gates.

## Failure handling and tradeoffs

AX requests have a 5 s deadline and 2 s cooldown after failure; the worker is killed
rather than leaving the input daemon trapped in Apple's translation framework.
Workers exit when their parent disappears. A startup owner that never becomes
ready is killed at the client's 20 s total deadline or after its parent dies.
Cancellation releases socket waits and skips subsequent batch steps. An input
already accepted by the simulator may finish; nothing automatically replays it.

Display geometry uses CoreDevice's active interface orientation independently of
AX. Screenshots, point size, OCR and touch coordinates now agree in landscape.
A missing or ambiguous report refuses input. Multiple integrated displays are
not qualified and fail explicitly rather than guessing panel routing. The
read-only geometry query adds one bounded round trip on non-watch commands.

Settling compares screen fingerprints without repeatedly requesting AX. It is a
bounded animation heuristic, not an outcome assertion. Tests verify status values,
exact text and screenshot content separately.

Only recognized inactive daemon logs and OCR artifacts are pruned. Daily automatic
maintenance and `cleanup --dry-run` share the same implementation; active owners,
unknown files, user screenshots/recordings and lock files are preserved. Old guest
helper caches are not executed or silently removed.

## Remaining limits and failed experiments

- **Accurate OCR remains unreliable on this host.** Vision stalled in Apple text
  model/ANE compilation with CPU/default compute, multiple revisions and the newer
  API. Even a 120 s isolated probe failed. Those experiments were reverted. Fast
  OCR works; uncertain/ambiguous targets fail safely and screenshots remain usable.
  A 32-label corpus is too small to claim universal recognition accuracy.
- Cold iOS initialization under severe host memory pressure (load >400) failed
  setup/AX readiness before input could be qualified. A warm six-case iPad run
  passed. These are separate results; no boot-time reliability claim is made.
- The first landscape text failure exposed a fixture layout switch triggered by
  keyboard avoidance. The fixture now preserves the focused view hierarchy.
- Full orientation switching could not be completed when DeviceHub's window became
  unavailable. Landscape is live-tested; all four mathematical transforms are
  contract-tested. Do not claim four live orientation passes from this evidence.
- Older Xcode/runtime combinations and multi-panel devices require separate live
  qualification. The required GitHub live gate exercises its available iPhone runtime.
- Private framework connection setup and kernel calls are not universally
  interruptible. A bounded client wait does not cancel work accepted by CoreSimulator.

## Reproduce

```sh
swift build -c release
swift test
bash examples/dtuhid-contract.sh
bash examples/display-contract.sh
python3 examples/transport-smoke.py .build/release/wand
python3 examples/protocol-regressions.py .build/release/wand
python3 examples/lifecycle-regressions.py .build/release/wand
python3 examples/native/ci.py # creates and removes exactly one disposable iPhone
# Explicit existing disposable watch only; never the production QA account:
WAND_SMOKE_CYCLES=50 WAND_CROWN_CYCLES=50 swift examples/watch/touch-smoke.swift WATCH_UDID "$PWD/.build/release/wand" /tmp/wand-evidence
python3 examples/resource-check.py .build/release/wand WATCH_UDID --output /tmp/wand-rss.json
```

The protected QA watch remained shut down throughout this reliability review.
