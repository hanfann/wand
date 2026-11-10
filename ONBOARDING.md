# Onboarding — Wand

Wand lets AI agents (and you) drive a booted iOS Simulator end-to-end: read the
screen (accessibility tree **or** on-device OCR), tap/type/swipe/drag-drop/pinch/
rotate, manage apps, and assert results — **no app changes required**.

## Get going (3 steps)

```bash
# 1. Install (builds a release binary, installs the shared Claude/Codex skill)
./install.sh              # or: brew tap hanfann/wand && brew install wand

# 2. Boot a simulator + your app
wand boot "iPhone 17 Pro"
wand install ./MyApp.app && wand launch com.example.myapp

# 3. Drive it
wand ui                  # what's on screen (token-efficient)
wand tap "Continue"      # by visible text — falls back to OCR if needed
wand typein "#email" "me@x.co"
wand assert "#welcome" exists
```

First call boots a background daemon and warms accessibility (a few seconds,
once). Warm AX reads can be ~60 ms; input commands also wait for settling.

## Mental model

- **Observe** → `wand ui` (on-screen elements) · `wand see` (OCR every visible
  text) · `wand find <q>` · `wand scrollto <sel>`.
- **Act** → `tap / typein / setvalue / clear / swipe / drag / dragdrop / pinch /
  rotate`. Address things by `eN` ref, `#identifier`, `"label"`, or `x y`.
- **Verify** → `wand assert <sel> [exists|gone|value=…|label=…]` (exit 0/1).

You do **not** need to add `testID`s — visible text is enough (Wand uses Apple
Vision OCR as a fallback). Adding `testID`/`accessibilityIdentifier` just makes
targeting more precise.

## For agents

- `wand setup` installs `skills/wand/SKILL.md` to `~/.agents/skills/wand/`
  for Codex and links Claude's skill to the same file.
- Use the CLI plus skill for the smallest context. `batch` combines known steps.
- Optional MCP: `wand mcp --compact` (one tool); register with `wand setup --mcp`.
  The legacy tool catalog remains available with `wand mcp`.
- Select a device with `--udid` or `WAND_UDID`. Wand refuses ambiguous defaults.
- On an app-only watch AX tree, try filtered `see` once, then use screenshots if
  needed. OCR has a deadline and cannot wedge the input daemon. Watch screenshots
  are often 2×; divide pixel coordinates by the `wand info` scale before tapping.
- Reuse one DeviceHub window, keep the host unlocked, and shut down task-owned
  throwaways after testing. See the skill for watch-specific handling.

## Develop / test

```bash
make build      # debug build
make test       # unit tests (swift test)
make e2e        # gesture regression vs the native showcase
make showcase   # build + launch the SwiftUI showcase
```

Architecture and internals: see `README.md`. Two runnable example apps live in
`examples/` (SwiftUI + Expo/React Native) and double as the regression suite.

## Requirements

macOS, full Xcode with the target Simulator SDK, Swift 6. Watch input was
revalidated on Xcode 27.2 / watchOS 27.2; older native backends remain available.
