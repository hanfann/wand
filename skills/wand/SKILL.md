---
name: wand
description: Autonomously E2E-test apps in the Apple Simulator (iOS, iPadOS, watchOS) — read the screen (accessibility tree OR on-device OCR), tap/type/swipe/drag-drop/pinch/rotate, manage apps, and assert results. Use when asked to test, QA, drive, or reproduce a flow in an iOS, iPadOS, or watchOS simulator app (React Native, Expo, native SwiftUI, or any app). Token-efficient: reads structured text, not screenshots. Works even with NO accessibility setup via Vision OCR.
---

# Wand — iOS Simulator E2E for agents

Wand drives a **booted iOS Simulator** with real HID touches and reads the
screen two ways: the **accessibility tree** (precise, semantic) and **on-device
Vision OCR** (works on any app, even with zero accessibility setup). A warm
daemon keeps it fast (~60 ms snapshots). No third-party dependencies.

## The loop

1. **Observe** — `wand ui`. One line per element:
   `e5 Button "Tap me" #tapButton @102,171`
   - `e5` ref · role · `"label"` · `#id` (RN `testID` / SwiftUI `accessibilityIdentifier`)
     · `=value` · `@x,y` **tap-ready center**.
   - If the tree is sparse (canvas/games/webviews, or an app with no testIDs),
     use **`wand see`** — OCR of every visible text + tap coordinates.
2. **Act** — by `ref`, `#id`, `"label"`, raw `x y`, or **visible text**:
   - `wand tap "#tapButton"` · `wand tap e5` · `wand tap 102 171`
   - `wand tapocr "Continue"` — taps visible text via OCR (no a11y needed)
   - `wand tap "Continue"` — tries the tree, then **falls back to OCR**
   - `wand typein "#email" "me@x.com"` · `wand setvalue "#email" "me@x.com"`
     (setvalue writes any unicode/emoji directly; great for long/odd strings)
3. **Verify** — `wand assert "#status" label=done` → `PASS`/`FAIL` (exit 0/1).

After acting, `wand ui` again. Off-screen elements report scrolled positions —
scroll first, then re-snapshot. To scroll, use **`wand scroll up|down`** (swipe-based;
iOS · iPadOS · watchOS). On watchOS, **`wand crown up|down`** drives the Digital Crown.

## Works without app changes (important for vibe-coded apps)

You do **not** need the app to add `testID`s. Visible text is enough:
- Native SwiftUI and RN `Text`/`Pressable`/`TextInput` already expose their text
  as labels — tap them by `"label"`.
- For anything else, `wand see` + `wand tapocr "<text>"` reads pixels via Apple
  Vision (on-device, no network). This covers buttons/labels/fields in almost any
  app. Only icon-only targets with no text/label are ambiguous — use coordinates.

## Commands

```
ui [diff|full]       see              find <q>         screenshot [path]
scrollto <sel>       assert <sel> [exists|gone|value=..|label=..]   wait <sel> [ms]
tap <sel|x y>        tapocr <text>    longpress <sel|x y>
typein <sel> <text>  type <text>      setvalue <sel> <text>
clear <sel>          key <hidUsage>
swipe <x1 y1 x2 y2>  drag <x1 y1 x2 y2 | fromSel toSel>   dragdrop <…>
pinch <sel|x y> <scale>     rotate <sel|x y> <radians>
scroll up|down [clicks]     # swipe-based scroll (iOS · iPadOS · watchOS)
crown up|down [clicks]      # watchOS Digital Crown (raw: crown <delta> [steps])
devices  boot <udid|name>  shutdown <udid|all>
install <app>  launch <bundle>  terminate <bundle>  apps  open <url>
logs [bundle] [seconds]   crashes [bundle]    # see why a step failed
permission <grant|revoke|reset> <service> <bundle>   record <start [path]|stop>
info  status  start  stop          (target a sim with --udid <udid>)
```
`<sel>` = `eN` · `#identifier` · `"label"`.

- `ui` shows **on-screen** elements only (token-lean). Use `ui full` for the whole
  tree (incl. off-screen), `ui diff` for just what changed.
- To act on something below the fold: `wand scrollto "<sel>"` first, then tap.
  When a label matches several elements, `ui`/`find` lists each with its own ref —
  tap the exact `eN`.

## Complex gestures

Use `@x,y` from `ui`, or a selector directly:
- `wand dragdrop "#card" "#trash"`   (drag-and-drop by element)
- `wand pinch "#map" 2.0`            (zoom in; <1 zooms out)
- `wand rotate "#photo" 1.57`        (≈90°)

## A full flow

```
wand boot "iPhone 17 Pro"
wand install ./MyApp.app && wand launch com.example.myapp
wand wait "#welcome" 8000
wand tap "Continue"            # by visible text — works without testIDs
wand typein "#email" "a@b.co"
wand assert "#error" gone
```

## Tips

- First call boots the daemon + warms accessibility (a few seconds, once); then ~60 ms.
- Prefer `ui`/`see`/`assert` over `screenshot` to save tokens.
- **Prefer label/ref taps over raw `x y`.** `tap "<label>"` · `tapocr "<text>"` ·
  `#id` · `eN` are robust; raw coordinates are the last resort, for targets with
  no label (icon-only buttons).
- **Coordinates are *points*, and only `ui`/`see` report them correctly.** The
  `@x,y` from `ui`/`see` are simulator points. A `screenshot` is at native scale
  (2×–3× on most devices), so any coordinate you eyeball off a screenshot is ~2×
  too large and lands off-target — often off-screen entirely, where the tap
  silently no-ops. Never read tap coordinates from a screenshot; take them from
  `ui`/`see`.
- React Native: a plain `View`'s `testID` only shows in the tree if the view is
  `accessible={true}`; `Pressable`/`TextInput` are fine. When in doubt, tap by
  visible text (OCR) instead.
