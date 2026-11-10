# Contributing

Thanks for your interest in Wand!

## Dev setup

```bash
git clone https://github.com/hanfann/wand && cd wand
make build      # debug build
make test       # unit tests (swift test)
```

Boot a simulator, then drive it: `./.build/debug/wand ui`.

## Layout

- `Sources/WandEngine/` — Obj-C engine. Talks to Apple's private CoreSimulator /
  SimulatorKit / AccessibilityPlatformTranslation frameworks (HID injection,
  accessibility tree, screenshot, OCR). No third-party code.
- `Sources/WandKit/` — pure, simulator-free screen model and batch validation (unit-tested).
- `Sources/wand/` — daemon, CLI, MCP server, simctl wrapper.
- `examples/` — SwiftUI + Expo/React Native showcases that double as the E2E
  suite (`examples/*/e2e.sh`).
- `skills/wand/SKILL.md` — shared Claude/Codex skill; `wand setup` installs it.

## Before a PR

- `make test` passes.
- Run the E2E suite for the input path changed. For watchOS 27 use
  `examples/watch/touch-smoke.swift` on an explicit disposable watch with Settings
  visible. Never use a stateful QA account for transport regression tests.
- `python3 examples/transport-smoke.py .build/debug/wand` checks lost replies and MCP.
- Update help, skill, README and changelog when commands or setup behavior change.
- Keep the **zero third-party runtime dependency** rule: only Apple frameworks
  shipped with Xcode, plus `xcrun simctl`.
- Match the surrounding style; keep comments about *why*, not *what*.

## Releasing

`git tag -a vX.Y.Z`, push, then bump `url`/`sha256` in `Formula/wand.rb` (here
and in the `homebrew-wand` tap). `release.sh` builds a universal binary.

By contributing you agree your work is licensed under the MIT License.

For optimization changes, use [the performance gates](docs/performance.md), compare
release binaries on the same device/screen, and retain the raw distributions.
`examples/protocol-regressions.py` exercises fragmented Unicode, incomplete replies,
pipelined MCP messages and invalid arguments without a simulator. Native build/E2E
scripts require an explicit `WAND_UDID` pointing to a disposable iOS device.
