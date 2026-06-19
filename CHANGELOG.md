# Changelog

All notable changes to Wand are documented here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/); versions are git tags.

## [0.1.0] — 2026-06-19

First release of wand — a fork of [testa](https://github.com/valewnrt/testa)
extended to Apple Watch, alongside iPhone and iPad.

### Added
- `crown up|down [clicks]` / `crown <delta> [steps]` — watchOS Digital Crown.
- `scroll up|down [clicks]` — swipe-based scroll (iOS · iPadOS · watchOS).
- Refuse to inject under an unsupported Simulator build instead of failing silently.

### Fixed
- Daemon self-heals across simulator reboots/erases (best-effort).

## [0.1.2] — 2026-05-22

### Fixed
- **Daemon failed to spawn when `wand` was run by bare name on `PATH`** (i.e.
  every Homebrew / installed setup). The executable path is now resolved via
  `_NSGetExecutablePath` instead of the unreliable `argv[0]`, so CLI commands
  and MCP tool calls work when installed, not just when run by relative path.

### Added
- README demo GIF + badges + an honest "Limitations" section.
- `CONTRIBUTING.md` and this `CHANGELOG.md`.

## [0.1.3] — 2026-05-22

### Added
- `wand logs [bundle] [seconds]` — recent app console output (via `simctl … log show`).
- `wand crashes [bundle]` — newest crash report for the app, if any.
  Both are independent, public-API implementations (no third-party tooling).

## [0.1.1] — 2026-05-22

### Added
- `wand setup` — one command installs the Claude Code skill and registers the
  MCP server. `install.sh` and the Homebrew formula now delegate to it, so
  `brew install wand` is fully one-shot.

## [0.1.0] — 2026-05-22

Initial release.

### Engine
- HID injection via the Indigo wire format (`SimDeviceLegacyHIDClient`): tap,
  long-press, swipe, drag-and-drop, pinch, rotate, multi-touch, keyboard.
- Accessibility tree via `AXPTranslator` with a token-delegate XPC bridge.
- In-process framebuffer screenshot (IOSurface → CGImage).
- On-device **Vision OCR** — tap visible text on any app, no `testID` needed.
- Universal text entry (`setvalue`, any unicode/emoji); SpringBoard remediation.

### Tooling
- Warm daemon over a `0600` per-user Unix socket; thin CLI; MCP server (`wand mcp`).
- Token-efficient snapshots (refs, viewport-only, `find`, `assert`, `ui diff`),
  `scrollto`, real auto-settle, daemon resilience, multi-simulator.
- App lifecycle (boot/install/launch/terminate/apps/open/permission), video record.
- Claude Code skill; Homebrew formula + tap; `install.sh`; CI; unit tests.
- Two showcase apps (SwiftUI + Expo/React Native) that double as the E2E suite.

Zero third-party runtime dependencies. Verified on Xcode 26.4 / iOS 26.4.
