# Performance and correctness acceptance criteria

Run release binaries on the same Mac, Xcode/runtime, simulator and screen. Keep
the host unlocked, use one disposable simulator at a time, and preserve account
data. Record sample counts, median, p95, maximum, output bytes and failures. Never
count a successful input acknowledgement as a successful app transition.

These are local regression budgets, not hardware-independent service guarantees.
Established before the deep-audit candidate was measured:

| Check | Acceptance criterion |
|---|---|
| Warm CLI / 20-command read batch | p95 under 50 ms |
| 128 KB transport response | p95 under 50 ms; complete UTF-8 payload |
| Screenshot on 40mm watch | p95 under 100 ms, valid full-resolution PNG |
| Fast OCR, watch Settings | fresh recognition under 1 s; exact-image hit under 100 ms |
| AX stall | worker killed by 5.5 s; coordinate input and stop still succeed |
| MCP cancellation | active socket released within 500 ms; queued input never sent |
| Display geometry | upright screenshot and matching input/AX points in verified orientations |
| OCR stall | fast worker killed by 3.5 s / accurate by 5.5 s; next info under 100 ms |
| OCR fallback recovery | one capture for both modes; no new worker during 60s automatic cooldown; explicit retry allowed; cancellation never starts cooldown |
| Daemon cold start, ready simulator | under 10 s, exactly one daemon; no guest HID helper |
| Watch tap including settling | p95 under 2 s on Settings navigation |
| Navigation | zero incorrect screen transitions in 100 observed actions |
| Native Watch Crown | scroll down and return to top; screenshot content must change/restore |
| iPhone gestures | 6/6 app outcomes: tap, long press, pinch, rotate, drag/drop, exact text |
| Input recovery | no automatic replay after ambiguous delivery; successful next observed action |
| Control-plane failure | monotonic subprocess deadline, bounded output, no replay after timeout |
| Subprocess output overflow | exact final byte tail with unchanged truncation/status/deadlines; 32 MiB emitter with 8 MiB tail improves p95 by at least 20%; small-output p95 stays within the regression budget |
| Framing | Unicode, fragmented/coalesced messages, bounded frames, partial EOF rejected |
| Large-frame scanning | at least 20% lower isolated 4 MiB framing p95; unchanged UTF-8/order/limits/cancellation; report complete CLI timings separately |
| Invalid input / batch | no NaN crash, no silent numeric zero, validate all steps before first action |
| Observation | diff exposes movement, disabled state, ref changes and duplicate removals |
| Compact MCP catalog | under 1 KB minified; preserve explicit targeting |
| Optional batch summary | at least 80% fewer UTF-8 response bytes on the 32-step fixture; identical execution order, exact final/error text, no replay |
| Optional screenshot preview | preserved full PNG; correct crop/orientation and independent X/Y point mapping; no upscaling; at least 70% fewer PNG bytes on the saved iPad fixture at 640px |
| CI change filtering | docs-only skip; source/tests/workflows/fixtures/unknown changes and unavailable diffs require macOS; docs runs cannot cancel code qualification |
| Resource use | daemon plus worker RSS growth below 20 MB over 1,000 warm reads; idle CPU under 1% over 5 s |
| Cleanup | no task-owned helper/worker/recording process or scratch files after stop; no extra running sims |

For performance-only changes, require at least 20% or 5 ms improvement in the
affected path. Reject a change if a related p95 regresses by both over 20% and
over 5 ms, or any correctness gate fails. Safety fixes may add bounded overhead;
report that tradeoff. Timing samples are empirical, not statistical proof across
all machines. Report untested platforms/features and failed gates explicitly.

## Reproduce

```sh
swift test
bash examples/dtuhid-contract.sh
bash examples/display-contract.sh
python3 examples/lifecycle-regressions.py .build/release/wand
swift build -c release
python3 examples/transport-smoke.py .build/release/wand
python3 examples/performance.py .build/release/wand --output /tmp/wand-perf.json
# Interleave two CLI binaries against the same stub daemon (not live simulator work):
python3 examples/performance.py .build/release/wand --compare-to /path/to/baseline/wand --output /tmp/wand-compare.json
# Existing booted disposable watch only; these commands do not boot/reset it:
python3 examples/performance.py .build/release/wand --udid WATCH_UDID --output /tmp/wand-live.json
WAND_SMOKE_CYCLES=50 swift examples/watch/touch-smoke.swift WATCH_UDID /absolute/path/to/wand /tmp/wand-smoke
```

The isolated transport test uses a fake local daemon to remove CoreSimulator
variance. Live results must be reported separately. Batch ping speedups measure
process/socket overhead, not animation speed. Catalog bytes are a reproducible
context-size proxy, not exact model token counts. OCR speed and OCR recognition
quality are separate: a fast wrong answer does not pass an accuracy gate.

The full watch suite deliberately fails if native Crown does not move content.
For diagnosing independent touch/batch behavior after recording that failure,
`WAND_SMOKE_SKIP_CROWN=1` runs a labelled subset; it cannot establish a full-suite
pass. `examples/resource-check.py WAND UDID --output result.json` measures RSS and
idle CPU over 1,000 warm AX reads. Simulator startup, compilation, and unrelated
load must not be mixed into warm latency comparisons.

Control-plane subprocess limits: list/getenv/terminate 15 s, ordinary simctl 30 s,
install 60 s, boot readiness 120 s; process identity scan uses 5 s. DTUHID first
input probes a live peer (4 s deadline, up to 3 attempts with 4 s backoff for a
nonresponsive peer); permanent lookup/symbol failures return immediately. Only
harmless probes retry, never input. Warm dispatch has a 2 s send-barrier deadline. Timeout diagnostics explicitly warn that the simulator may
have applied the operation. These bounds do not cancel work already accepted by
CoreSimulator. AX calls are isolated in a worker with a 5 s deadline. Other
private framework calls are not universally interruptible. Startup ownership
waits have a 20 s total deadline, and an unready owned child is stopped on expiry.
