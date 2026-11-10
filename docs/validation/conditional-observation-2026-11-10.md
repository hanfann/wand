# Conditional observations and inline MCP images — 2026-11-10

Accepted: skip redundant preview work and image delivery after a **fresh** capture,
and attach final images to the action's MCP response. These are independent,
opt-in improvements. No app-specific logic or lower-confidence OCR/input behavior
was added to the engine. Legacy screenshot responses remain unchanged.

## Objective gates and results

| Gate | Result |
| --- | --- |
| Fresh capture on every request; detect one changed pixel, device, geometry, crop/preview settings | PASS, unit tests |
| Preserve original PNG and preview bytes/mapping | PASS, all three offline sizes and live MCP |
| 20 identical observations deliver one image | PASS, offline and live watch; all 20 captures still occur |
| Large-image unchanged preparation p95 improves ≥20% or 5 ms | PASS, 97.4% iPad and 96.7% phone |
| Related p95 cannot regress by both >20% and >5 ms | PASS; small watch unchanged adds 0.070 ms |
| Invalid request sends no input; failed delivery never replays input | PASS, protocol/unit tests |
| Compact catalog below 1 KB | PASS, 545 minified bytes |
| Live actual navigation, not merely successful dispatch | PASS, 10/10 transitions, reference-region error 0 |
| Task resource cleanup | PASS, selected daemon stopped and disposable watch shut down |

96 Swift tests passed (30 executable + 66 library). Simulator-free protocol,
transport, lifecycle/cancellation and CI process-ownership tests passed. Raw logs,
benchmark samples and representative watch images are in
[the evidence directory](conditional-observation-2026-11-10/).

## Measurements

Saved-frame replay uses production response code, 3 warmups then 30 interleaved
samples per mode. Includes fresh file write, image validation, hashing and response
preparation; excludes simulator capture/PNG encoding and model processing.
Builds, tests and simulator boot were finished or stopped before these measurements.

| Source / 640px preview | Legacy p95 | Unchanged p95 | Forced fresh p95 |
| --- | ---: | ---: | ---: |
| iPad, 2316×1512 px | 35.987 ms | 0.953 ms | 35.889 ms |
| Phone, 1170×2532 px | 22.364 ms | 0.732 ms | 22.550 ms |
| Watch, 324×394 px (no resize) | 0.288 ms | 0.358 ms | 0.536 ms |

The watch CPU path is slightly slower because it already skipped resizing. Its
benefit is fewer image deliveries. Twenty identical captures delivered one image
instead of twenty (95% fewer PNG bytes): iPad 1,229,620 → 61,481; phone 778,620 →
38,931; watch 744,840 → 37,242. These are **not measured model-token savings**.
Clocks, animations and changed PNG metadata can conservatively invalidate a token.

A native ImageIO thumbnail experiment was rejected: only 8–9% / 2.8–3.2 ms p95
improvement, below the 20% or 5 ms gate, with different rendered PNG bytes. The
production preview renderer remains unchanged. At under 1 ms on these fixtures,
further response-preparation micro-optimization has reached a practical plateau;
this does not establish a universal plateau across devices or workloads.

## Live qualification

macOS/Xcode/watchOS 27.2, explicit disposable 40mm watch
`48B1CAAD-E31C-4E3D-BF36-2F8665006E89`, 162×197 points, 324×394 pixels.
Backed up its available Keychain before boot; no Belly container was present.
Protected QA `B0CDF864-C040-4465-A6CB-0AF65EDD8D02` stayed shut down and untouched.
No DeviceHub window was created. Boot took about 65 seconds, excluded from timings.

A persistent compact MCP client performed 20 observations then five Settings →
Notifications → Settings round trips. Every navigation response included the exact
saved PNG and correct 0.5 pixel-to-point scales. All ten transitions matched the
reviewed reference below the clock (sparse normalized RGB check, observed error 0;
representative full images were also inspected). A fresh caller received an image.
Repeated MCP observations took **8.981 ms p95**; 19 omitted the unchanged image.
This is transport/observation latency, not complete model-driven task latency.

Two follow-up profiles placed screenshot acquisition/encoding at 8.4–14.9 ms and
observation processing at 0.8–1.1 ms. Both returned changed images: the first token
had expired across a clock tick, and the second explicitly requested `none`.
These two diagnostic samples identify where time goes, not a distribution.

## Contract and tradeoffs

`--since none` returns an exact SHA-256 token over PNG bytes plus device, captured
point geometry and presentation settings. The caller retains its own token/image;
there is no global baseline that another agent can overwrite. Matching tokens
omit the preview/image payload but still save a fresh full PNG. Visual equality
does not prove hidden app state or action success. If context is lost, use `none`.

MCP `image:true` validates the full batch before input, requires a final screenshot,
uses a 640px preview by default and returns standard PNG content with mapping.
Image reads are bounded to 2 MiB and 4096px per edge. An attachment failure reports
that commands completed and asks for another screenshot, never action replay.
Single-call attachment removes a separate image-open call; no model-turn or token
speedup was measured. Explicit output paths are caller-owned; avoid sharing them
across concurrent clients. Defaults isolate MCP process/device captures.

## Next priorities and remaining limits

1. Observation preparation is now below 1 ms in saved-frame tests. Avoid further
   complexity here without evidence of a larger workload-specific bottleneck.
2. Next major latency target is simulator capture/encoding and settling. Keep the
   watch's validated settling floor until actual cross-app outcomes establish a
   safe replacement; an app-only accessibility tree cannot establish readiness.
3. Large-device live capture/gesture and accurate-OCR qualification still require
   a healthy iOS test environment. Han deferred another-Mac qualification; do not
   repeatedly cold-boot iOS on the host that previously overloaded. Saved phone
   and iPad replay does not close that live-platform gap.
4. OCR remains optional, AX first and direct screenshot inspection when AX is
   incomplete. This change does not improve the known pixel-font OCR failure.

The prior GitHub run `42833099897` passed Xcode 26.6 unit tests, then failed a CI
cleanup test when macOS denied a late group signal. The helper now verifies that
no live group members remain before accepting such a denial, preserves the original
exception, and tests denied live groups/unavailable inventories. Xcode 27.2 live
installation remained blocked in that run. The new run
[42839712156](https://github.com/hanfann/wand/actions/runs/42839712156) passed builds,
all unit tests, protocol/cancellation/cleanup regressions and smoke checks on both
Xcode versions. Both live gates then failed during the 60-second `simctl install`,
before Wand input; process diagnostics and shutdown also timed out. Runtime
selection was compatible: iOS 26.5 with Xcode 26.6, iOS 27.2 with Xcode 27.2, both
iPhone 14. This supports an environment/setup blocker but does not establish its
root cause or successful iOS input qualification. No live gate was removed or
weakened. Exact job conclusions and failure excerpts are in `ci-result.json`.

## Reproduce

```sh
swift test
swift build -c release
python3 examples/protocol-regressions.py .build/release/wand
python3 examples/transport-smoke.py .build/release/wand
python3 examples/lifecycle-regressions.py .build/release/wand
python3 examples/native/ci-test.py
python3 examples/observation-benchmark.py \
  docs/validation/reliability-2026-11-10/ipad-final/type.png \
  --points 1158 756 --output /tmp/ipad-observation.json
python3 examples/observation-benchmark.py \
  docs/validation/reliability-2026-11-10/ci-xcode26-651b47f/portrait/tap.png \
  --points 390 844 --output /tmp/phone-observation.json
python3 examples/observation-benchmark.py \
  docs/validation/workflow-profiling-2026-11-10/ocr-source.png \
  --points 162 197 --output /tmp/watch-observation.json
# Explicit disposable 40mm watch, already booted, Settings root visible:
python3 examples/watch/observation-check.py .build/release/wand WATCH_UDID \
  --output /tmp/watch-observation
# Caller stops its selected daemon and shuts down its disposable fixture afterward.
```

The checked-in watch runner packages the successful live sequence with configurable
paths/UDID and temporary helper cleanup. Its packaged form was syntax/help checked;
the recorded live run used the equivalent sequence before packaging.
