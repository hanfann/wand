---
name: wand
description: Drive and test iOS, iPadOS, and watchOS simulators with Wand. Use for simulator automation, UI QA, touch gestures, and Digital Crown input.
---

# Wand

Use the installed CLI through the normal command tool; `wand help` lists commands.
`wand setup` updates this shared Claude/Codex skill from the repository/install.
After a binary update, restart only your task's selected daemon (`stop`) to load it.

## Observe, act, verify

- Choose with `wand devices`. Pass `--udid <ID>` on every command or set task-scoped
  `WAND_UDID`; Wand refuses an ambiguous default. Follow the app's backup/account rules.
- Read `info` (point size + scale) and `ui`. With a useful tree, prefer `find <query>`,
  `ui diff` and `assert <selector> [exists|gone|value=…|label=…]` over full snapshots.
- Watch AX often exposes only the app. Repeating `ui`/`find`/`wait` will not reveal
  missing controls. AX runs in a persistent worker with a 5s deadline; a stuck
  worker does not wedge coordinate input or stop. Try filtered `see "text"` once; use `screenshot <path>` if OCR
  fails. Accurate Vision currently stalls on the tested Xcode 27.2 host; do not
  repeatedly retry it. OCR deadlines
  are 3s fast / 5s accurate; a stall leaves input usable.
- `tap` accepts `eN`, `#id`, visible labels, or `x y`. Missing refs/IDs fail without
  OCR. OCR taps require a unique, confident match; duplicate labels fail. Exact
  fast matches are tried first; uncertain/missing text uses accurate fallback.
  Accurate Vision model initialization can time out on macOS 27. Use screenshot
  coordinates then; repeating the same failed query is not progress. Observe after navigation/layout changes
  before reusing coordinates/refs; eN refs expire after input. Ambiguous/disabled/off-screen AX input targets fail before input; use a fresh
  ref or unique ID. Named targets refresh geometry; asynchronous app changes can still require a fresh observation.
- Screenshots and point coordinates follow the active interface orientation.
  Unsupported or ambiguous display geometry fails before input.
- Touches use **points**; screenshot positions use **pixels**. Divide screenshot
  coordinates by the `info` scale before tapping. `ui`/`see` already report points.
- `scroll down` uses touch; `drag 80 165 80 65` gives slower, precise scrolling.
  `crown` sends native Digital Crown events on watchOS; verify the resulting
  state. Touch scrolling is useful for navigation but is not a Crown test.

Batch only known steps whose next action does not depend on an unseen result:

```sh
wand --udid <ID> batch '[["tap","40","80"],["ui","diff"]]'
# Or pipe the same JSON into: wand --udid <ID> batch -
```

Batches preserve settling and stop at the first error; earlier steps stay applied.
Lost replies/ambiguous input are never replayed automatically. Inspect before
retrying. Successful dispatch alone does not prove the expected app state changed.

## Watch / cleanup

Xcode 27 uses one persistent host DTUHID connection for touches, multitouch,
keyboard and Crown; no guest helper is compiled or spawned. `info` reports the
selected transport. An interrupted connection fails loudly: inspect the screen,
then `stop` the selected daemon before retrying. Never replay ambiguous input.
DeviceHub shows real actions: reuse one window and select devices in
its sidebar. Keep the Mac unlocked for visible checks and app launches; a lock is
not a reason to spawn windows or reset a watch.

`boot` is headless; add `--show` only when a viewer is needed. Keep only needed sims running. `wand --udid <ID> stop` closes its daemon/HID connection,
not the simulator. Shut down task-owned throwaways afterward; preserve unrelated
processes and stateful QA accounts. Erase/delete/uninstall is not routine cleanup.
Keep requested evidence, remove scratch captures. Watch input regression:
`examples/watch/touch-smoke.swift`, explicit disposable watch, Settings root visible.
iOS input regression: `examples/native/e2e.sh` on an explicit disposable
`WAND_UDID` with the native fixture installed. Both suites check actual app
outcomes. Compatibility evidence: `docs/validation/hid-closeout-2026-11-10.md`.
Runtime/device coverage and current limits are recorded in
`docs/validation/reliability-2026-11-10.md`.

## Optional MCP

CLI plus this skill avoids a tool catalog. `wand mcp --compact` exposes one `run`
tool with `udid` and `commands` (same batch format). `wand setup --mcp` registers
compact mode with Claude; `mcp` / `setup --full-mcp` retain legacy tools.
Cancellation skips queued work and stops subsequent batch steps; earlier input
may already have applied. Observe before resuming.

`cleanup --dry-run` previews inactive diagnostics; `cleanup` applies retention.
Startup also runs maintenance at most daily. It preserves active logs, locks,
recordings and user screenshots. Startup has a 20s total deadline and kills only
its own unready child. A timeout does not justify retrying an ambiguous gesture.
