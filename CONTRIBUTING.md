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
- `Sources/WandKit/` — pure, simulator-free screen model (unit-tested).
- `Sources/wand/` — daemon, CLI, MCP server, simctl wrapper.
- `examples/` — SwiftUI + Expo/React Native showcases that double as the E2E
  suite (`examples/*/e2e.sh`).
- `skills/wand/SKILL.md` — the Claude Code skill.

## Before a PR

- `make test` passes.
- `make e2e` passes against the native showcase (needs a booted sim).
- Keep the **zero third-party runtime dependency** rule: only Apple frameworks
  shipped with Xcode, plus `xcrun simctl`.
- Match the surrounding style; keep comments about *why*, not *what*.

## Releasing

`git tag -a vX.Y.Z`, push, then bump `url`/`sha256` in `Formula/wand.rb` (here
and in the `homebrew-wand` tap). `release.sh` builds a universal binary.

By contributing you agree your work is licensed under the MIT License.
