# Wand deep performance and correctness audit — 10 November 2026

> Follow-up: both input failures described below were subsequently fixed and
> verified. See [Xcode 27 HID closeout](hid-closeout-2026-11-10.md). The original
> measurements and failed experiments remain here as historical evidence.

## Verdict

The retained changes improve transport efficiency, bound failure paths, reduce
temporary-object accumulation, and simplify command execution. **This is not an
all-platform input sign-off.** The audit reproduced two Xcode 27 failures:

- Native Digital Crown acknowledged commands without scrolling the 40mm watch.
  It also failed with the pre-audit executable, after DeviceHub attachment and
  daemon reconnection. Touch scrolling worked.
- The iOS 27.2 native fixture failed all six gesture outcomes. Some commands
  acknowledged input without changing app state; others rejected the native HID
  message. Reading the accessibility tree and framebuffer worked. An experiment
  using the watch guest bridge on iOS also failed all six outcomes and was reverted.

Do not interpret a HID acknowledgement, unit-test pass, or faster transport as
proof that these input paths work. These failures take priority over more speed
work before a release advertised as fully supporting Xcode 27 input.

## Scope and method

Reviewed startup/device selection, socket framing, command validation, batches,
HID delivery/recovery, settling, accessibility snapshots/diffs, screenshots/OCR,
MCP, app diagnostics, worker lifecycle, installation/skills, CI and test harnesses.

Environment: Apple M4, 10 cores, 24 GiB, macOS 27.2, Xcode 27.2 (27B52).
Watch: existing disposable 40mm SE, watchOS 27.2. iOS: a newly created disposable
iPhone 17 Pro, iOS 27.2. Only one simulator was booted at a time. Production QA
B0CDF864 was never booted, reset, installed over, or driven.

Release binaries were compared using [the acceptance criteria](../performance.md).
Most latency checks have 30 samples; catalog throughput has 10 runs of 100 requests.
Raw distributions, environment/binary hashes and test logs are in
[the evidence directory](deep-audit-2026-11-10/).

The baseline is the locally installed pre-audit binary, including the preceding
uncommitted batch/OCR work; it is **not** GitHub main. Host load and DeviceHub
attachment varied. Trials overlapping our builds/boot activity were discarded.
Later paired trials are retained separately, including unfavorable results.

## Measurements

| Check | Observed result | Assessment |
|---|---|---|
| 128 KB reply, initial comparable runs | Median 68.65 → 18.93 ms; p95 72.66 → 22.19 ms | About 3.6× faster; retained buffered transport |
| 128 KB reply, later paired run | Median 109.19 → 16.03 ms; p95 138.09 → 18.79 ms | Same improvement direction; larger ratio is load-confounded |
| Warm `info`, later candidate | Median 14.41 ms, p95 19.15 ms | Under 50 ms budget |
| Warm `ui`, later candidate | Median 31.11 ms, p95 41.63 ms | Under 50 ms budget; not a speed win |
| 20-ping batch, later candidate | Median 17.01 ms, p95 33.64 ms | Under 50 ms budget; not a speed win |
| Watch screenshot, later candidate | Median 33.76 ms, p95 46.38 ms, max 120.32 ms | p95 under 100 ms; tail outlier retained |
| Watch tap including settling | 32 samples, median 1.480 s, p95 1.646 s | Under 2 s budget; no settling reduction |
| Refactored dispatch tap check | 8 samples, median 1.479 s, p95 1.558 s | Small regression check, not a new speed claim |
| RSS growth over 1,000 AX reads | 4.83 → 0.22 MiB in the autorelease-pool comparison | Less accumulation; absolute RSS varied ~28–42 MiB |
| Idle daemon CPU | 0% measured over 5 seconds in both runs | No measured idle CPU cost |
| Eight simultaneous starts after stop | 1 daemon, ~1.045 s elapsed with cached helper | Singleton gate passed |
| Stop with recording active | ~0.105 s; no recording process left | Cleanup gate passed |
| Compact MCP catalog | 502 bytes, 1 tool versus 7,103 bytes, 27 tools | Earlier 92.9% reduction preserved; bytes are not exact tokens |

The later paired `ui` p95 rose from 31.44 to 41.63 ms, and batch p95 from 19.84 to
33.64 ms. These exceed the relative-regression threshold despite passing absolute
budgets. They are **not** claimed as improvements. Load was variable, and the
autorelease-pool change is retained for bounded resource lifetime, not speed.
A quiet, counterbalanced benchmark is still needed before claiming an overall
latency improvement across every command. The large-response transport gain is
the repeatable speed result; bootstrap process-count reductions are not assigned
an invented end-to-end percentage.

## Correctness results

- 27 simulator-free unit tests passed: snapshots, batches, invalid numeric input,
  framing, monotonic deadlines, pipe draining, bounded diagnostic output and
  subprocess failure handling.
- Protocol checks passed: lost/unterminated replies do not replay input; large
  fragmented UTF-8 is preserved; coalesced MCP requests retain all responses;
  missing/invalid coordinates send no input; numeric values and selector hold
  duration survive MCP translation.
- Watch Settings: **100/100 tap/back transitions** passed screenshot comparisons.
  Representative screens were visually checked. Helper recovery and singleton
  checks passed. The full suite then **failed Crown return-to-top**.
- Explicitly labelled touch-only subsets passed navigation, drag/scroll,
  recovery, batch preflight and stop-on-error checks. They do not turn the full
  suite into a pass. Late invalid numeric arguments prevent earlier batch input.
- Forced unsupported HID refused input while read-only `info` remained usable.
- iOS native fixture: **0/6 outcomes passed** (tap, long press, pinch, rotate,
  drag/drop, typing). The failed shared-bridge experiment is recorded separately.
  The fixture now exposes setup/input errors rather than hiding them and checking
  stale status text.
- Release build, shell syntax, skill validation and diff whitespace checks passed.

One hundred repetitions of the same navigation pair are a regression check,
not proof of universal reliability or a 99.9% success rate across applications.

## OCR accuracy and latency

On one Settings screen with four fixed labels (excluding the clock), fast OCR
matched 2/4 labels exactly; accurate OCR matched 4/4. Fast mode misread
“Notifications” and “Smart Stack.” The accurate call completed in ~0.643 s and
the fast call in ~0.837 s in that particular cold comparison; other fast samples
were ~0.21–0.49 s and identical-image hits ~0.02–0.04 s. Mode names do not guarantee
which individual cold call is faster.

Accurate OCR had previously hit its 5 s deadline on this same Mac; the earlier
report documents recovery. It succeeded during this audit. Deadline enforcement
remains necessary. A four-label screen is insufficient to qualify recognition
across custom fonts, languages and app layouts. Proposed next qualification:
at least 20 labelled screens per supported app/font class, >=95% exact-target
recall, and zero incorrect target activations. Report abstentions separately.

## Retained changes and refactor

1. **One command execution path.** Single calls and batch steps share validation
   and HID error checks. Batches execute argument arrays directly instead of
   serializing/parsing JSON for every step. App diagnostics are separated from
   UI dispatch.
2. **Buffered transport.** A shared line reader retains surplus MCP messages,
   handles fragmented Unicode, rejects partial/oversized frames and uses total
   monotonic read deadlines. Sockets are close-on-exec; writes handle EINTR.
   Incoming requests have a 5 s deadline, client replies 300 s, frames an 8 MiB
   cap. A missing reply remains ambiguous and is never automatically replayed.
3. **Validated inputs.** NaN/infinity, malformed coordinates, unbounded counts,
   empty selectors and invalid assertion conditions fail before input. Full
   batches are preflighted. MCP no longer defaults missing gesture coordinates
   to zero or loses integral numeric values/selector long-press durations.
4. **Accurate observations.** Diffs expose moved/resized/disabled controls,
   changed refs and duplicate removals. Named targets refresh their geometry;
   positional refs expire after input. Missing elements cannot pass an assertion
   merely because the expected value is empty. `wait` tolerates transient missing
   AX roots after launch within its polling budget.
5. **Shared subprocess runner.** SDK/helper and simctl work drains output while
   running, retains a bounded diagnostic tail and has explicit time limits.
   Timeout errors warn that an operation may have applied; no automatic retry.
   See the criteria document for per-command limits. This does not cancel work
   already accepted by CoreSimulator or bound private in-process AX calls.
6. **Lifecycle and resources.** One process scan replaces pgrep plus per-PID ps;
   app metadata uses native plist parsing instead of PlistBuddy/plutil/tempfiles.
   Per-command autorelease pools bound temporary lifetimes. Stop/stale teardown
   releases sockets/workers/recording before acknowledgement; concurrent `start`
   uses the same startup lock. The unnecessary 200 ms startup sleep is removed.
7. **Operational clarity.** Boot is headless unless `--show` is requested, using
   the selected Xcode's DeviceHub/Simulator. Lifecycle failures return failure
   status. Native tests require an explicit disposable UDID and fail on setup
   errors. Shared skill/docs expose the input limitations.

## Experiments rejected

- **In-memory PNG staging for OCR cache hits:** about 2 ms improvement, below
  the 20%/5 ms retention threshold. Reverted; no claimed OCR pipeline speedup.
- **Shorter/sparser UI settling:** earlier navigation regression and no measured
  gain. Not reintroduced. UI correctness takes precedence over a faster ack.
- **Watch guest HID reused for iOS:** acknowledgements but 0/6 app outcomes.
  Reverted; the unverified transport is not installed.

## Remaining opportunities, in priority order

| Priority | Area | Work and objective exit criterion |
|---|---|---|
| P1 | Xcode 27 iOS input | Determine the correct device HID route/ABI; require all six fixture gestures and observed state changes, repeated across iPhone/iPad sizes |
| P1 | Native Crown | Establish delivered Crown events independently of touch scrolling; 100 up/down observed transitions with DeviceHub attached and detached |
| P1 | AX liveness | Bound or isolate private AX work; inject an AX stall and prove input/stop recovery without replay. Current outer semaphore waits can outlive client deadlines |
| P2 | Perception quality | Multi-app ground-truth OCR corpus; measure exact-target precision/recall and abstentions. Do not use text-cache age or a coarse screen fingerprint for target reuse |
| P2 | Latency regressions | Quiet counterbalanced runs for `ui`/batch p95; profile AX/XPC and autorelease costs before changing timing or caching |
| P2 | MCP cancellation/errors | Define cancellation of queued versus already-applied commands, and explicit malformed-request errors; never replay an ambiguous mutation |
| P2 | CI coverage | Make supported runtime/device outcome tests required before a compatibility release; current best-effort live smoke is insufficient |
| P3 | Screenshot/OCR encoding | Profile raw framebuffer hashing/shared memory only if PNG work dominates a real workflow; earlier small memory-staging change failed the retention gate |
| P3 | Helper startup | Consider direct runtime metadata/cached process discovery only with boot-session invalidation; preserve SDK/architecture/source cache identity |
| P3 | Large trees/output | Profile duplicate-heavy 3,000-node trees, targeted queries and batch output caps; preserve geometry/state accuracy and meaningful diagnostics |
| P3 | Cache/log maintenance | Add explicit bounded retention for obsolete helper builds/logs; never remove files still used by a live daemon or unrelated account backups |

Do not optimize by dropping HID acknowledgements, replaying uncertain gestures,
shortening all settle delays, opening extra simulators/windows, or reporting a
touch-scroll fallback as Crown coverage. Those can improve superficial timings
while making the tool less trustworthy.

## Delivery and cleanup

The resulting release binary and shared Claude/Codex skill are installed locally.
Source changes remain uncommitted and unpushed. Raw measurements, concise logs and four representative screenshots
are retained; bulk scratch screenshots, the experimental iOS helper and the
task-created iOS simulator are removed. The existing watch is preserved and shut
down. Briefly paused wallpaper workers on the disposable iOS device were resumed
before its final functional checks; no such pauses are left behind. Unrelated
daemons, accounts and simulator data are preserved.
