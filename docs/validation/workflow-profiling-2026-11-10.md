# Workflow profiling and deferred frame sampling — 2026-11-10

**Accepted for measured watch CPU efficiency.** App-independent profiling and
scenario benchmarks identified avoidable framebuffer work during the existing
watch settling floor. Deferring that work reduced median daemon CPU by 52–55%
per navigation round trip. Complete workflow latency improved much less: 2–9%
at p95. These are distinct results, not a claim that whole agent tasks are twice
as fast. Exact OCR quality still fails on this fixture.

## Method and scope

macOS 27.2 (26B123), Xcode 27.2 (27B52), watchOS 27.2; existing disposable 40mm
watch `48B1CAAD-E31C-4E3D-BF36-2F8665006E89`, 162×197 points, 324×394 pixels.
No app-specific behavior was added to Wand. Settings labels, coordinates,
references and clock exclusion live only in a scenario file. The generic runner
also accepts AX/text assertions without any screenshot or watch requirement.

Baseline was `dd8a9e1` plus opt-in instrumentation, before changing settling.
Both release binaries used the same instrumentation. The candidate changed only
the settling mechanism relevant to these inputs. Binary SHA-256:

* Baseline: `e0958005319498ebd184cc06d9df5bdce11209721203e4888763890ab71df72e`
* Candidate: `4c8aa98bc8e0a670270997447d10566867eb40cab6a431e9985b60edf87d654f`

Order: baseline 25 cycles → candidate 25 → candidate 5 → baseline 5. Each cycle
has an ordinary and a batched round trip; their order reverses each cycle.
The large blocks were sequential, not randomized per action. Reverse-order
repetition confirmed the CPU effect, but latency remains sensitive to host load.
Boot, compilation, daemon startup and fixture preparation are excluded from the
navigation distributions. Preflight/startup results are retained separately.

Both the intermediate Notifications screenshot and final Settings screenshot
must match independently reviewed references. This avoids counting a batch that
misses both taps as successful. Sparse image comparison verifies screen identity,
not clipping or every pixel. Representative full screenshots were also inspected.

## Main comparison

Each navigation row has 25 verified round trips (50 actions) per binary. Combined
ordinary/batch navigation establishes 100 observed actions per binary, with zero
incorrect transitions. The repeated blocks add another 20 per binary.

| Workflow | Wall median, baseline → candidate | Wall p95 | Daemon CPU median | Mean frame checks |
|---|---:|---:|---:|---:|
| Ordinary navigation | 2,574 → 2,488 ms | 2,819 → 2,761 ms | 125.54 → 56.69 ms (−54.8%) | 22.76 → 7.36 |
| Batched navigation | 2,537 → 2,410 ms | 2,763 → 2,506 ms | 125.63 → 60.92 ms (−51.5%) | 22.32 → 7.36 |

Reverse-order repeat medians: ordinary CPU 151.89 → 60.10 ms; batch CPU
150.97 → 71.40 ms. Each repeat has five samples, so its tail estimates are weak.
Raw maxima remain in the JSON: ordinary main-run maximum was 2,851 → 2,880 ms;
the improvement is not a universal worst-case guarantee.

In the baseline, exclusive framebuffer work represented about 13% of navigation
daemon wall time; it is about 2.5% in the candidate. Waiting now accounts for
about 91%. The one-second watch minimum is unchanged. The candidate starts
sampling near the end of that interval, still requires three equal samples,
and continues checking cancellation at intervals no longer than 90 ms. The
phone's 180 ms minimum still starts sampling immediately. Deterministic tests
cover changing frames, cancellation during deferred sampling, missing frames,
deadline termination and phone sampling. Live iOS qualification was not rerun.

Native Crown, visual inspection and failed-batch recovery passed in both main
and repeat runs. Their main-run single samples were respectively 4,225 → 4,307 ms,
43 → 48 ms and 2,562 → 2,876 ms. These small samples establish outcomes, not strong
latency distributions. No related latency increased by both over 20% and 5 ms.

## Profiling, resources and failure evidence

* Profile/plain warm `info` reads interleaved for 30 samples each: p95 12.31 vs
  11.80 ms, a 0.51 ms overhead. Original result text matched in every sample.
* 1,000 individual profiled requests: daemon RSS 27,136 → 27,136 KB (zero growth).
* 1,000 ordinary AX reads: daemon plus worker RSS 67,792 → 68,080 KB (+0.28 MB);
  idle CPU over five seconds was 0% at the measurement's resolution.
* Exact fast OCR **FAIL**: visible “Notifications” was returned as “7 Notif ications”
  and “Smart Stack” as “mart Stack”. The final exact-text test failed in 140 ms.
  Speed does not make this an accuracy pass. No fuzzy target relaxation or repeated
  accurate-OCR retry was introduced to hide the failure.
* Cold iOS/accurate-OCR qualification remains deferred under the prior host-capacity
  decision. The native text scenario is supplied but **not live-qualified here**.

CPU measures the daemon only, not workers, CoreSimulator or GPU. Exclusive phase
times are additive; inclusive parent/child times are not. CLI calls and UTF-8/PNG
bytes are recorded, but they do not establish agent turn counts or model tokens.
Scenario output paths differ in length, so small result-byte differences between
binary runs are not an optimization result.

Validation: 87 Swift tests, seven workflow-runner tests, six CI-scope tests, release
build, transport/protocol/lifecycle regressions and HID/gesture/display contracts.
Workflow tests require explicit outcomes, exclude failed samples from successful
percentiles, reject missing references and support an arbitrary text-only app.
Profile tests cover nested exclusive accounting, errors, stdin/preflight and
non-replay after a lost reply.

## Reproduce and next decisions

Use [the workflow guide](../workflow-benchmarks.md) with
`examples/watch/settings-workflows.json`. Use `examples/profile-overhead.py` for
interleaved read overhead and 1,000-profile retention; `examples/resource-check.py`
measures daemon plus AX worker. The adjoining `restore-baseline-settle.patch`
restores the old instrumented sampling loop in a separate checkout so another
comparison can be built (`git apply --unidiff-zero <patch>`). Stop the selected
daemon before switching binaries.

The next ranked opportunities are:

1. **Outcome-aware readiness:** highest potential latency reduction because waiting
   is now about 91% of navigation time. Needs distinct, reliable destination state,
   proof it was not already true before input, and real transition qualification.
   App-only watch AX cannot provide that. Do not shorten the floor blindly.
2. **Observation quality and choice:** exact OCR failure causes costly fallback and
   agent uncertainty. Build a reviewed cross-app text/image corpus before changing
   recognition or target matching; retain confidence and ambiguity safeguards.
3. **Agent workflow calls:** this fixture's batch reduces four CLI calls to one with
   the same two screenshot checks. Measure real task traces before assigning a
   model-latency/token benefit or treating test frequency as real usage frequency.
4. **Broader qualification:** run the native text/gesture scenarios on a healthy iOS
   host. Architecture is app-independent; coverage on one watch app is not evidence
   of correctness on every app, runtime or orientation.

Raw profiles, summaries, screenshot hashes and representative captures are in
the adjoining directory. Original `/tmp` capture paths in JSON are provenance;
only selected screenshots are retained. The disposable watch's available Keychain
was backed up before boot to `~/wand-workflow-40mm-backup-20261110-181759.tgz`
(176,236 bytes; no matching Belly data containers). Production QA `B0CDF864` was
untouched. The task daemon and disposable simulator were stopped after validation; zero
simulators remained booted. Scratch captures were removed after retaining this evidence.
