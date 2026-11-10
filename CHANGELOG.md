# Changelog

All notable changes to Wand are documented here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/); versions are git tags.

## [Unreleased]

- Isolate accessibility in a persistent worker with a 5 s deadline; stop workers
  after owner death. Bound startup ownership, cancellation and subprocess drains.
- Keep MCP responsive to cancellation without replaying ambiguous input.
- Align screenshots, input and AX coordinates using active display orientation;
  reject ambiguous/malformed display geometry before sending input.
- Reject ambiguous, disabled and off-screen AX input targets; share field setting
  between `clear` and `setvalue`, with exact identifier precedence.
- Set AX values directly so opening a keyboard cannot hide the target first;
  reject unsupported HID Unicode before tapping and map printable US ASCII fully.
- Prefer unique, confident exact fast-OCR targets; reject ambiguous/uncertain hits.
- Prune only recognized inactive diagnostics, with dry-run and daily maintenance.

- Accessibility initializes on demand, so `info`, `launch`, and `stop` no longer
  require an eager accessibility snapshot during daemon startup.

- Shared subprocess runner with monotonic deadlines, bounded diagnostic output and
  no retry on timeout; transient missing AX roots no longer immediately abort `wait`.
- Shared command dispatch for single calls/batches, without JSON re-encoding each
  batch step; app diagnostics extracted from UI dispatch.
- Buffered, bounded NDJSON transport; fragmented UTF-8 and persistent MCP framing
  tests. Missing replies remain non-replayable.
- Validate numeric input and batch steps before action; preserve MCP integer values
  and selector long-press durations; reject missing gesture coordinates.
- UI diffs retain duplicate controls and expose geometry/ref/enabled changes.
  Named targets refresh geometry; positional refs expire after input.
- One process scan for boot identity; native plist parsing; per-command autorelease
  pools; recorder cleanup on stop. Concurrent `start` uses the startup lock.
- Headless boot by default, opt-in `--show` for DeviceHub/Simulator, and real failure
  exit codes. Reproducible performance and resource budgets in `docs/performance.md`.

### Added
- Ordered `batch` commands and optional one-tool `mcp --compact`, with explicit
  per-call simulator targeting and stop-on-failure semantics.
- Shared Claude/Codex skill installation. MCP registration is now opt-in with
  `setup --mcp`; source installs retain the skill beside the installed binary.
- Filtered `see [accurate] [query]`; bounded CPU OCR worker with exact-image caching.

### Changed
- Multiple booted devices require an explicit target rather than choosing the first.
- Load SimulatorKit only for legacy input/layout diagnostics and the accessibility
  framework only inside the AX worker. Cache toolchain discovery per process.

### Fixed
- Read legacy interface orientation from the one active display rather than
  assuming screen ID 0. Ignore disconnected outputs and reject ambiguous panels.
- Encode legacy single-finger drag moves as continued contacts; propagate pinch
  and rotation failures at down, movement and release instead of returning success.
- Select compatible runtime/device pairs in CI, avoiding accidental use of a
  device-specific foldable runtime for the ordinary iPhone fixture.
- Xcode 27 uses one persistent host DTUHID connection for touch, multitouch,
  keyboard and native Watch Crown. Removed the guest helper and its SDK/compiler
  subprocesses. Bounded liveness probes precede input; interruptions fail without
  replay. Xcode 26 and earlier retain the legacy Indigo path.
- Lost command replies never trigger an automatic replay of potentially applied input.
- Missing AX identifiers/refs do not invoke OCR for strings that are not visible labels.
- OCR initialization stalls no longer wedge the input daemon.

- Load SimulatorKit from `Contents/SharedFrameworks` too. Newer Xcodes moved it
  there, so the daemon failed to start with `SimulatorKit=0x0`.

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
