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
| Native gesture contract | Pass: single-contact down/move/up packets; pinch/rotate fail at each injected delivery phase without continuing |
| Display contract | Pass: all four transforms; valid, malformed, inactive and ambiguous reports |
| Lifecycle | Pass: startup lock deadline, kill unready owned child, worker/startup parent death |
| MCP cancellation | Pass: active socket released under 500 ms, queued input skipped, next request healthy |
| Transport | Pass: fragmented Unicode, partial EOF, no lost-reply replay, persistent requests |
| Compact catalog | 502 bytes versus 7,142 bytes; 93% less serialized catalog, not an exact token count |
| Watch AX fault injection | Frozen worker fails in 5.013 s; next tap 427 ms, screenshot 105 ms, stop 15 ms |
| Final watch candidate | 20 navigation actions, 10 Crown transitions, batch/preflight guards pass; tap p95 1,362 ms |
| Lazy-loading watch candidate `d52e4b1` | Pass: 10 navigation actions, 6 Crown transitions, drag, batch/preflight guards; tap p95 1,537 ms; daemon startup 1,392 ms |
| Native Crown | 100 actual down/up transitions passed on the 40mm watch; screenshot comparisons |
| iPad landscape | Seven of seven gesture/text outcomes passed, including Unicode; upright 2316×1512 screenshots |
| Xcode 26.6 / iOS 26.5 hosted iPhone 14 | Commit `651b47f`: complete CI pass, portrait 7/7 and landscape 3/3, including legacy drag and exact ASCII/Unicode text |
| Memory, daemon + AX worker | 1,000 warm reads: +0.297 MiB; idle CPU 0% |
| Final warm CLI / 128 KB reply p95 | 13.94 / 12.72 ms, both below 50 ms |
| Final warm info / AX / 20-ping batch p95 | 10.68 / 18.48 / 10.76 ms |
| Final watch screenshot p95 | 18.15 ms, below 100 ms |
| Final fast OCR, watch Settings | Fresh ~136 ms; cached median 16.65 ms |
| OCR accuracy corpus | **Failed overall gate**: fast 29/32 exact labels with correct centers; accurate 0/32 due to deadlines |

Memory and the 100-Crown run precede the final display/setvalue patches;
those changes are separately exercised by final live tests. The later target
guards/1 s watch settling candidate passes 41 unit tests and the final watch
suite (`unit-guards.txt`, `watch-settle.txt`). Xcode 26 hosted input passed on
`651b47f`; the later `d52e4b1` watch run separately validates lazy framework loading.
Do not describe the
whole table as one immutable-binary run. Raw samples include maxima and failures. `performance-final.json` records 30
quiet samples per warm path on the final candidate (10 for OCR). The earlier
performance run had higher host load; this is not a controlled speedup claim.
Ten further two-tap navigation batches passed with the revised settling floor
(`watch-batch-stress.txt`).

The final watch retest caught a batch timing failure after individual navigation
and Crown passed. The watch settling floor was raised from 650 ms to 1 s; the
2 s observed tap p95 budget remains unchanged. A hosted CI setup attempt timed
out in initial `simctl list` before any UI tests; its cold discovery allowance
was raised to 120 s without relaxing warm performance gates. Its old runner
also silently selected Xcode 16.4 through the fallback. CI now explicitly selects
Xcode 26.6 and 27.2 on their matching GitHub images, with no fallback to a different
major version. Runner availability was checked against the official
[GitHub image catalog](https://github.com/actions/runner-images).

The first explicit matrix reached simulator setup but both jobs timed out while
building/installing the fixture alongside a booted simulator. The harness now
compiles before boot, logs each phase, kills its owned subprocess group on timeout,
and preserves setup/cleanup diagnostics even when UI tests never start. Its
process-group timeout and cleanup-after-diagnostics-failure tests pass.

The first legacy reader incorrectly treated screen ID 0 as the main panel. A
headless iPhone 14 probe showed ID 1 at 1170×2532 pixels and three disconnected
zero-size outputs. Selection now requires one nonzero-size display; the live
probe reads portrait correctly, and contracts cover disconnected/multiple
outputs plus the 1 s stall deadline without accumulating work.

Hosted Xcode 27 setup failures also exposed a fixture-selection bug: choosing a
runtime by version alone selected the iPhone Duo-specific 27.2 runtime, then
silently substituted a Duo for the requested iPhone. Runtime and device are now
selected as a compatible pair from a single-screen fixture allowlist, with a
regression test for equal-version general and device-specific runtimes. Previous
Duo setup failures do not establish ordinary iPhone startup reliability.

The corrected Xcode 26 run reached the real fixture: tap, long press, pinch,
rotation and Unicode entry passed. Drag failed because the older single-contact
builder rejects mouse-drag event 6, leaving a contact down and contaminating the
following text case. Legacy single-contact moves now use continued-down packets;
DTUHID keeps its native move phase. The native contract exercises the real builder
without a simulator, and injected failures verify that pinch/rotate return errors
at down, movement and release. The live suite now stops on an input error instead
of measuring subsequent cases in potentially contaminated state.

The follow-up [Xcode 26.6 job](https://github.com/hanfann/wand/actions/runs/42767931915/job/129668718115)
passed: all seven portrait and three landscape outcomes, with screenshots and
successful owned-simulator cleanup (`ci-xcode26-651b47f/`).

The corrected Xcode 27 selection did use an ordinary iPhone 14, but its 60 s
fixture installation timed out and even `ps` diagnostics exceeded 5 s; no Wand
input ran. A local fresh iPhone 14 also exceeded a 90 s install allowance after
its display probe passed. Both owned devices were shut down and deleted. These
are retained startup failures, separate from the earlier successful warm live
input runs. No warm latency budget was relaxed to hide them.

The next Xcode 27 attempt completed installation but exceeded Wand's 20 s
startup deadline before input; process diagnostics also stalled. Startup review
found eager loading of SimulatorKit and the accessibility framework even for
modern coordinate commands. DTUHID now loads CoreSimulator alone; legacy Indigo
and the layout diagnostic load SimulatorKit explicitly, while AX loads its
framework in the isolated worker. Toolchain discovery is cached per process,
removing repeated `xcode-select` subprocesses. The native contract verifies modern
startup leaves the legacy framework unopened before explicitly testing its builder.

Commit `d52e4b1` passed the local watch suite after host load settled: 10
navigation actions, 6 native Crown transitions, drag and batch safeguards, with
tap p95 1.537 s and daemon startup 1.392 s (`watch-lazy-d52e4b1/`). The watch
was then shut down. Two preceding attempts did not qualify input: one harness
used the iPhone Settings bundle ID on watchOS; the corrected attempt hit a 120 s
OS boot deadline. The final run used `com.apple.NanoSettings`, the existing
180 s CI boot allowance, and the unchanged Wand command/performance budgets.

The latest hosted run did not reach input: Xcode 26 timed out launching the
fixture; Xcode 27 timed out installing it, with `ps` also stalled. Xcode 27's
shutdown exceeded its deadline but deletion returned successfully; this is
recorded as a cleanup failure, not a clean pass. The draft PR's live CI gate
remains red. No fresh iOS startup or full-platform reliability claim is made.

A further local run with 47% reported free memory installed the fixture and
started Wand, then timed out on app launch. A retained-fixture investigation
subsequently timed out on installation and the read-only `get_app_container`
query. At that point host load was 545.94/281.91/162.21 with 34% memory reported
free; the process inventory showed exactly one `launchd_sim`, belonging to this
task. Shutdown completed in 4.45 s and deletion in 0.44 s. This does not establish
RAM as the sole cause; fresh iOS startup itself remains unqualified. No unrelated
simulators or processes were terminated.

Han confirmed that another test Mac is unavailable and asked to document these
blockers for now. Remaining work is to qualify cold iOS startup and accurate OCR
on a stable alternate host/runtime, then rerun the required live gates. The
installed binary remains the watch-verified `d52e4b1` build. Production QA watch
`B0CDF864` remained shut down; local test simulators and owned workers were stopped.

## Failure handling and tradeoffs

AX requests have a 5 s deadline and 2 s cooldown after failure; the worker is killed
rather than leaving the input daemon trapped in Apple's translation framework.
Workers exit when their parent disappears. A startup owner that never becomes
ready is killed at the client's 20 s total deadline or after its parent dies.
Cancellation releases socket waits and skips subsequent batch steps. An input
already accepted by the simulator may finish; nothing automatically replays it.

Xcode 27 display geometry uses CoreDevice's active interface orientation
independently of AX. The Xcode 26 live gate exposed its missing CoreDevice display
service, so older hosts read the primary `SimScreenProperties.uiOrientation`
instead, bounded to 1 s with no accumulating stuck reads. This is presented
orientation, not physical attitude; see the independent
[protocol observations](https://github.com/sethdeckard/deviceterm/blob/main/Sources/CoreSimulatorBridge/as-tested.md#display-orientation). Screenshots, point size, OCR and touch coordinates now agree in landscape.
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
  Scaling fast OCR 2×/3× fixed one label but introduced other mistakes, so no
  preprocessing was added. A 32-label corpus is too small to claim universal recognition accuracy.
- Cold iOS initialization under severe host memory pressure (load >400) failed
  setup/AX readiness before input could be qualified. A warm six-case iPad run
  passed. These are separate results; no boot-time reliability claim is made.
- The first landscape text failure exposed a fixture layout switch triggered by
  keyboard avoidance. The fixture now preserves the focused view hierarchy.
- Full orientation switching could not be completed when DeviceHub's window became
  unavailable. Landscape is live-tested; all four mathematical transforms are
  contract-tested. Do not claim four live orientation passes from this evidence.
- Xcode 26.6/iOS 26.5 has the explicit successful run above; other older
  combinations and multi-panel devices require separate live qualification.
  The required GitHub live gate exercises its available iPhone runtime. CI prefers
  iPhone 14 on 7 GiB runners. Earlier Xcode 27 attempts accidentally selected
  iPhone Duo and timed out before input; those remain failed setup attempts,
  not input passes or evidence about iPhone 14.
- Private framework connection setup and kernel calls are not universally
  interruptible. A bounded client wait does not cancel work accepted by CoreSimulator.

## Reproduce

```sh
swift build -c release
swift test
bash examples/dtuhid-contract.sh
bash examples/gesture-contract.sh
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
