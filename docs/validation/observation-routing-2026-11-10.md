# Observation routing and qualification — 2026-11-10

Keep accessibility as the default structured observation, use agent-interpreted
screenshots for custom/canvas/pixel UI, and keep OCR optional. No recognition,
target-matching, confidence or automatic-fallback implementation changed in this
pass. The shared skill now makes screenshot work independent of OCR success.

## Why OCR is not the main path

The local comparison used six saved screens from three apps: Watch Settings,
the native iPhone/iPad showcase, and two Belly reward screens. There were 21
distinct manually annotated labels, repeated three times (63 target observations,
not 63 independent labels). No simulator was booted and no tap was dispatched.
Only the four already-public Settings/showcase screens and their observations
are referenced in the repository. Belly images/text remain local; only aggregate
counts are retained. This small corpus is diagnostic, not general OCR qualification.

| Fast OCR variant | Exact text | Correct centers | Centers passing existing confidence threshold |
|---|---:|---:|---:|
| Baseline | 42/63 | 42/63 | 0/63 |
| Small-image 2× scaling | 45/63 | 45/63 | 0/63 |
| Small-image 2× nearest-neighbor | 45/63 | 45/63 | 0/63 |
| Small-image 3× scaling | 45/63 | 45/63 | 0/63 |
| Contrast inversion | 42/63 | 39/63 | 0/63 |
| Language correction | 42/63 | 42/63 | 0/63 |

All observed fast-mode confidence values were 0.5, below Wand's 0.8 fast-path
threshold. This is an observation about this host/corpus, not a universal promise
about Vision. Exact text alone did not establish an eligible automatic target.
Inversion recognized “Notifications” in the wrong annotated region, illustrating
why geometry matters. Scaling recovered isolated labels without establishing
targeting reliability. None of the preprocessing variants was adopted.

Apple describes [fast versus accurate recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlevel)
as a speed/accuracy tradeoff. That does not establish either mode's suitability
for a particular app or permit treating low-confidence results as certain.
The experimental helper reproduces the fast request configuration but has its own
process startup overhead; recorded timings are not a production speedup claim.
The initial production-worker run also returned 42/63 exact/correct-center results.

## Better evaluator, bounded cost

`examples/ocr/evaluate.py` now distinguishes exact text, target geometry and the
existing automatic-target confidence thresholds. It measures latency once per
screen, records malformed replies explicitly and preserves ambiguous matches.
Off-screen bounds remain ineligible even if the center falls inside a target.

Default evaluation runs fast mode only. Accurate mode must be selected explicitly
with `--modes accurate` (or `--modes fast accurate`). After the first worker timeout,
that mode skips its remaining screens while retaining them in the denominator.
Skipped work has no fabricated timing. A fake-worker regression verifies one
worker attempt and seven skipped screens for an eight-screen timeout case. This
bounds the timeout allowance to one 5.5-second attempt instead of eight (44 seconds),
excluding process setup/termination overhead. No live accurate-OCR retries were run.

```sh
python3 -B examples/ocr/test_evaluate.py
python3 -B examples/ocr/evaluate.py .build/release/wand examples/ocr/real-screens.json \
  --modes fast --samples 3 --output /tmp/ocr-results.json
# Optional read-only text-quality gate, distinct from target eligibility:
python3 -B examples/ocr/evaluate.py .build/release/wand examples/ocr/real-screens.json \
  --gate correct_center --output /tmp/ocr-readability.json
```

The default 95% targeting gate intentionally fails on this corpus. Lowering the
threshold to make the report green would conceal the limitation. The optional
`variants.swift` helper is an offline experiment, never part of Wand's runtime.

## CI follow-up

Run `42829551972` failed the Xcode 26.6 output-drain timing test: 3.392 seconds
against a three-second limit. That test included Python interpreter startup and
did not ensure that its descendant had begun writing before the parent exited.
The exact source of that CI delay was not established; the local replay was 51 ms.

The revised fixture compiles a small native writer outside the timed interval,
then synchronizes its parent exit with the start of descendant output. The same
three-second limit and bounded output assertions remain. A three-second child
alarm prevents a broken implementation from leaving a permanent writer.
Removing the drain-deadline check in an isolated mutation did **not** reliably
fail locally: a gap in the pipe also permits the reader to exit. That experiment
is inconclusive, not proof that this test uniquely detects removal of that guard.
No subprocess implementation or timeout was changed to address this CI result.

All 87 local Swift tests passed, along with six evaluator tests, seven workflow
tests and six CI-scope tests. Xcode 27.2 passed the previous run's unit/protocol
checks but failed before live input when simulator installation timed out; even
process diagnostics and simulator cleanup timed out there. Full hosted live
qualification remains unresolved. The new fixture still needs its new CI result.

Next performance work should measure the accessibility/screenshot observation
loop and verified destination readiness, with OCR as an optional branch. A single
app-only accessibility node cannot establish a screen transition. Device startup
failures should remain separate from actual input failures in the scorecard.
