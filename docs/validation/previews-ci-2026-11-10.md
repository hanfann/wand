# Screenshot previews and CI efficiency — 2026-11-10

Code commit: `7d8371f`. Installed release SHA-256:
`8085548635c8b926254066cf245566c303d753705da5130005ea01b522763172`.

## Previews

- All 65 Swift tests passed, including nine new parser/image tests. Release build
  and transport/protocol/lifecycle regressions passed, including invalid MCP
  preview options, exact path/crop forwarding and batch preflight.
- Existing iPad capture: 2316×1512 → 640×418 pixels (92.4% fewer pixels);
  273,361 → 61,481 PNG bytes (77.5% fewer bytes). The full PNG stayed byte-identical.
  This is image/file size reduction, not an exact model-token or latency claim.
- Visually inspected the derived iPad preview: upright, uncropped and readable
  for broad inspection. Small typography and clipping still require the original.
- Tests verify portrait/landscape orientation, top-right crop contents, source-pixel
  offsets, independent X/Y scaling after dimension rounding, out-of-bounds refusal,
  full-capture preservation and symlink-alias refusal. Small watch captures reuse
  the original without upscaling or creating another file.
- Point mapping is explicit in the returned JSON:
  `pointX = xOffset + previewX * xScale`, likewise Y. Coordinates use the preview's
  actual dimensions, not the full screenshot's scale. Crops use source pixels.
- Previews are derived from the saved full capture, never a second framebuffer
  read. The default screenshot path/response is unchanged. User captures/previews
  remain user-owned artifacts; temporary test previews are removed after review.

## CI

- Six classifier tests passed, including real temporary git history: docs edit,
  source addition and code renamed into a Markdown path. Unknown/empty/unavailable
  diffs run the full macOS matrix. A saved image consumed by preview tests is
  explicitly treated as a test fixture rather than documentation.
- Workflow YAML parsed locally. Hosted change classification for
  [the code commit](https://github.com/hanfann/wand/actions/runs/42780344044) passed
  and enqueued both Xcode jobs, retaining the required live gates.
- Known docs-only changes skip macOS jobs. Manual runs qualify both Xcodes.
- Cancellation is scoped to macOS jobs by branch/PR and Xcode, using GitHub's
  [job-level concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
  Docs-only runs enqueue no macOS jobs, so cannot cancel pending/running code
  qualification. Newer code jobs replace superseded jobs on the same target.
- No local simulator was booted or changed. Cold iOS setup and accurate Apple
  Vision OCR remain unresolved qualification limits. The prior batch commit's
  hosted builds/unit/contracts passed but live input jobs failed; this change
  does not reinterpret those failures as passes.

## Reproduce

```sh
python3 -B .github/scripts/ci_scope_test.py
swift test
swift build -c release
python3 examples/transport-smoke.py .build/release/wand
python3 examples/protocol-regressions.py .build/release/wand
python3 examples/lifecycle-regressions.py .build/release/wand
```
