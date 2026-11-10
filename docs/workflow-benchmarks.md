# Measure completed work

Wand's job is to let an agent observe and operate simulator apps, then verify the
intended outcome, with predictable latency and bounded resource/context use.
App logic, screen names and coordinates belong to tests. The input, observation,
profiling and settling implementations remain app-independent.

Use the same loop for each optimization:

1. **Observe:** collect representative successful and failed workflows, with
   phase timings and explicit outcome checks. Separate cold setup from warm work.
2. **Orient:** rank costs by measured frequency × cost × safely removable share.
   Record confidence and risk. Fixture frequency is not production usage frequency.
3. **Decide:** state a falsifiable hypothesis and correctness/performance gates
   before running the candidate. Change one mechanism at a time.
4. **Act:** compare release binaries on the same device and screen, alternate
   execution order where possible, inspect failures, and repeat the comparison.
   Keep a change only if its improvement clears the gate without correctness loss.
5. Re-profile after each accepted change. Record rejected ideas and blocked
   qualification so the next pass does not repeat expensive dead ends.

## Per-command profiles

```sh
wand --udid "$WAND_UDID" profile '["tap","40","80"]'
printf '%s' '["ui","diff"]' | wand --udid "$WAND_UDID" profile -
```

The command runs once. JSON includes `schema`, `ok`, original `result`, and
`profile`: elapsed milliseconds, daemon CPU milliseconds, original result UTF-8
bytes, and phase calls/inclusive/exclusive milliseconds. Failure still exits
nonzero and writes the JSON to stderr. A transport failure may produce the normal
plain diagnostic instead; do not automatically replay it. Nested profiles and
daemon/device lifecycle commands are rejected before dispatch. App launch/install
may be profiled explicitly. A batch is accepted and retains its usual semantics.

Only **exclusive** phase times are additive. For example, `settle` includes its
`frame_fingerprint` children in its inclusive total; adding both inclusive totals
would overstate work. CPU measures this daemon process, excluding workers,
CoreSimulator, the kernel and GPU. CLI elapsed minus profile elapsed includes
startup/transport/encoding and scheduling; it does not isolate any one of them.
Profiling adds response bytes and small measurement overhead; leave it off for
ordinary operation. Result content can contain app data, so retain reports with
the same care as screenshots.

## App-independent workflow runner

Compile the dependency-free macOS image helper once, outside the timed run:

```sh
swiftc examples/image-samples.swift -o /tmp/wand-image-samples
python3 -B examples/workflows.py .build/release/wand \
  --udid "$WAND_UDID" --confirm-disposable \
  --image-helper /tmp/wand-image-samples \
  --scenario examples/watch/settings-workflows.json \
  --output /tmp/wand-workflow-run --cycles 25
```

Prepare the fixture and satisfy its preflight yourself. The runner requires an
already booted explicitly selected device, creates a new output directory, and
never implicitly boots, installs, resets, retries input or deletes a device.
Scenario commands are explicit actions and can mutate app state. Follow account
safety rules before preparing or testing a device.

The supplied Settings scenario requires a 40mm watch at Settings root. It checks
100 navigation transitions across 25 ordinary and 25 batched round trips, plus
native Crown, visual inspection and failure recovery. BOTH intermediate and final
batch screenshots must match reviewed reference images. This is one fixture,
not universal app or runtime qualification. `settings-ocr.json` separately checks
exact OCR text quality; its failure must not be hidden by successful image checks.

A scenario has `preflight`, repeated `workflows` and optional `once` workflows.
Text-only scenarios need no image helper. `examples/native/text-workflow.json`
illustrates this against the native showcase; it requires separate live qualification.
Each workflow has a `name` and `steps`. A step is either:

* `{"command":["assert","#editor","value=hello"]}` — ordinary Wand command.
* `{"command":["see"],"contains":"Hello"}` — require literal output text.
* `{"command":["assert","#missing"],"ok":false,"contains":"FAIL"}` — expected failure.
* `{"image":"{output}/{sample}.png","reference":"home"}` — compare a captured PNG
  against `references.home`, whose path is relative to the scenario file.

Commands support literal `{output}` and `{sample}` placeholders, including inside
batch JSON. `image_region` is normalized `[x,y,width,height]`, defaulting to the
whole screen. The watch fixture explicitly excludes its changing clock/title.
Image checks use a sparse RGB mean-distance threshold (default 0.025), with optional
`different:true`. They establish coarse screen identity/change, not pixel-perfect
layout or clipping correctness. Review references and full screenshots separately.
Use AX assertions for exact app state where the app exposes them.

Every workflow requires an explicit assertion. A failed outcome stops the run and
saves partial results; failed rows remain failures and are excluded from successful
latency percentiles. Repeated workflow order reverses each cycle to reduce drift.
Swap baseline/candidate daemon binaries explicitly between comparison blocks;
replacing a CLI alone does not replace its already-running daemon.

`results.json` records raw commands, phase metrics, screenshot distances/size,
success counts, wall/CLI/verification latency, daemon CPU and response/image bytes.
CLI calls are not agent turns, bytes are not exact model tokens, and PNG compression
is not a measure of visual-model cost. Add representative app scenarios rather than
optimizing solely for this fixture. Keep curated evidence and remove scratch captures
after review; stop the selected daemon and shut down the task-owned simulator.
