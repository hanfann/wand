# Bounded subprocess output — 2026-11-10

The old subprocess reader appended each chunk, then copied the retained tail
whenever output exceeded its cap. At the default 8 MiB cap, each additional 16 KiB
read could copy another 8 MiB. `OutputTail` grows with actual output and then
overwrites old bytes in a circular buffer, linearizing once at the end if needed.
It retains at most the requested byte count; small outputs do not preallocate 8 MiB.

## Measured acceptance

Same Mac, optimized standalone builds of the actual `ProcessRunner`, baseline
source from `a9f648f`. Each case has one warm-up and 20 measured samples. The finite
C emitter writes real pipe output; every result is checked byte-for-byte. No
simulator or private framework is involved.

| Output / retained cap | Previous p95 | Candidate p95 |
|---|---:|---:|
| 4 KiB / 8 MiB | 17.57 ms | 20.27 ms |
| 256 KiB / 8 MiB | 16.11 ms | 16.74 ms |
| 32 MiB / 8 MiB | 399.93 ms | 27.35 ms |

Overflow p95 fell **93.2%**, exceeding the 20% improvement gate. Small-output
changes remain below the regression threshold (both >20% and >5 ms). These are
sequential local measurements, not a claim that ordinary UI commands became
faster. Raw samples, maxima and medians are in `output-tail-2026-11-10.json`.
Retained byte counts are tested; total-process peak RSS was not measured.

## Correctness

All **72 tests** and the release build passed. Tests cover empty/exact/zero/negative
limits, repeated wraparound, oversized replacement chunks, immutable snapshots,
1,500 deterministic chunk sequences against a reference tail, Unicode byte
truncation and exact subprocess exit status. Continuously emitting children still
hit their deadlines; exited parents cannot leave an unbounded output drain.

Release transport/protocol/lifecycle checks passed, including cancellation,
no replay, startup ownership and worker parent death. No simulator was booted.
Cold iOS setup and accurate Vision OCR remain separate known limitations.

Installed release SHA-256:
`fb5466cd4c3c53f382b19d4581ee57cac889f7030eea29cc97c927548b2e8cbf`.

## Reproduce

```sh
swift test
wand_bench_dir=$(mktemp -d)
clang -O2 examples/process-output-emitter.c -o "$wand_bench_dir/emitter"
swiftc -O Sources/WandKit/OutputTail.swift Sources/WandKit/ProcessRunner.swift examples/process-output-benchmark.swift -o "$wand_bench_dir/benchmark"
"$wand_bench_dir/benchmark" "$wand_bench_dir/emitter" /tmp/wand-output.json 20
# Optional baseline comparison with the same emitter and benchmark driver:
git show a9f648f:Sources/WandKit/ProcessRunner.swift > "$wand_bench_dir/before.swift"
swiftc -O "$wand_bench_dir/before.swift" examples/process-output-benchmark.swift -o "$wand_bench_dir/before"
"$wand_bench_dir/before" "$wand_bench_dir/emitter" /tmp/wand-output-before.json 20
rm -rf "$wand_bench_dir"
```
