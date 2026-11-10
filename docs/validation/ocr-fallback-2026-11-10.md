# OCR fallback optimization — 2026-11-10

Fast recognition and automatic accurate fallback now share one PNG capture and
hash. The latest exact image and point geometry retain separate fast/accurate
results. New operations still capture before consulting the cache; different
pixels or point dimensions invalidate both modes. Only one image's results are
retained.

An accurate timeout suppresses automatic accurate fallback for 60 seconds per
daemon. Fast OCR remains available. Explicit `see accurate` bypasses the cooldown;
successful accurate recognition clears it. Cancellation and ordinary worker errors
do not start cooldown. Suppression returns an error, never an uncertain tap.

## Validation

- All 48 tests passed: 41 existing tests and seven new OCR service tests.
- Release build passed. Binary SHA-256:
  `1e40c3026d115d136ece32b04f82f8871a4f2a91b4932f0fef6610a9cbcbb2c5`.
- Injected accurate worker stall: 5.082 seconds to timeout and termination.
- Twenty subsequent automatic retries: 21.29 ms total, zero new workers.
  These timings use a synthetic image and local stub worker; they do not measure
  simulator capture time or Apple Vision recognition speed.
- Shared-frame test: one capture, two workers reading the same file. Later
  alternating fast/accurate requests on unchanged pixels launch zero workers.
- Verified pixel/geometry invalidation, single-frame cache capacity, empty-result
  caching, 60-second cooldown expiry, explicit retry during cooldown, success
  recovery, cancellation without cooldown, and failed captures/malformed results.
- Every OCR test checks that no PNG/result scratch remains. Timeout tests verify
  worker termination. Release transport, protocol and lifecycle regressions pass,
  including cancellation, no input replay, startup ownership and worker parent death.
- No simulator was booted. Live Apple Vision accuracy and cold iOS startup remain
  the previously documented qualification blockers. Watch settling is unchanged.

## Reproduce without a simulator

```sh
swift test
swift build -c release
python3 examples/transport-smoke.py .build/release/wand
python3 examples/protocol-regressions.py .build/release/wand
python3 examples/lifecycle-regressions.py .build/release/wand
```

The OCR tests invoke the production service with a controlled executable and
capture callback. Worker deadlines remain the production 3/5 seconds; only the
cooldown clock is injected so expiry can be verified without a minute-long wait.
