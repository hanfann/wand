# Batch summary validation — 2026-11-10

`batch --summary <JSON|->` and compact MCP `run` with `summary: true` keep the
completed-step count and final result, or the exact failed step and error.
Intermediate successful output is not retained. Full output remains the default.
Both modes share the executor, command validation, settling and stop-on-error
behavior. CLI/MCP preflight invalid batches before simulator dispatch.

## Results

- All 56 tests passed, including six batch-execution tests and two new preflight
  tests. Tests cover failure at every position, cancellation before/after steps,
  no replay, exit propagation, Unicode/multiline results and default formatting.
- A synthetic 32-step fixture produced **641 → 46 UTF-8 response bytes**, a
  **92.8% reduction**, with 32 commands executed in each mode. This measures reply
  text, not model tokens or UI execution latency. One-step summaries can be larger.
- Release build and transport/protocol/lifecycle regressions passed. CLI argv and
  stdin, MCP optional/invalid flags, whole-batch preflight, exact error forwarding
  and lost-reply refusal were exercised through real CLI/MCP processes and a stub
  daemon. The compact tool catalog is 529 bytes, below the 1 KB budget.
- No simulator was booted. Input delivery and watch settling were not modified.
  Cold iOS startup and accurate Vision OCR remain separate known limits.

Release binary SHA-256:
`747b2764184c9a4d70a6a9bd078c94d3db65df6d07cbb2fa156d0dd8ff34fa74`.

## Command overhead

Comparison uses the installed `4c6756e` build and this release on the same Mac,
against a stub daemon; it excludes simulator work. Sequential 30-sample runs
showed a 128 KB p95 increase from 15.19 to 27.96 ms, triggering investigation.
A follow-up alternated old/new binaries and reversed their order every sample to
reduce time/order effects. Forty samples per binary/path gave:

| Path | Previous p95 | Candidate p95 |
|---|---:|---:|
| Small CLI reply | 20.84 ms | 21.65 ms |
| 128 KB reply | 16.58 ms | 15.17 ms |
| 20-command CLI batch, stub reply | 13.10 ms | 12.95 ms |

The controlled follow-up meets the 50 ms budgets and shows no regression above
both 20% and 5 ms. The initial excursion did not reproduce with interleaving;
no command-latency speedup is claimed. All samples, including the initial run,
are retained in `batch-summary-2026-11-10.json`.

## Reproduce

```sh
swift test
swift build -c release
python3 examples/transport-smoke.py .build/release/wand
python3 examples/protocol-regressions.py .build/release/wand
python3 examples/lifecycle-regressions.py .build/release/wand
python3 examples/performance.py .build/release/wand --output /tmp/wand-perf.json
```
