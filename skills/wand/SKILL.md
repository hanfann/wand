---
name: wand
description: Drive and test iOS, iPadOS, and watchOS simulators with Wand. Use for simulator automation, UI QA, touch gestures, and Digital Crown input.
---

# Wand

Use the installed CLI in the normal command tool (`wand help`). Prefer CLI plus
this skill to loading a tool catalog. `wand setup` updates the shared Claude/Codex
skill. After a binary update, `stop` only your selected daemon to load the new build.

## Observe, act, verify

1. Select with `devices`; pass `--udid <ID>` or task-scoped `WAND_UDID`. Ambiguous
   defaults fail. Follow the app's account/backup rules.
2. Read `info` and `ui`. Prefer `find`, `ui diff`, and `assert <sel>
   [exists|gone|value=…|label=…]` to repeated full snapshots.
3. `tap` accepts `eN`, `#id`, labels or `x y`. Missing IDs/refs fail without OCR;
   ambiguous, disabled or off-screen AX input targets fail. Refresh observations
   after navigation/layout changes: refs expire after input, named targets refresh
   geometry. `type`/`typein` support US ASCII; use `setvalue` for Unicode.
4. Watch AX may expose only the app. Repeated `ui`/`find`/`wait` cannot reveal
   missing controls. Try filtered `see "text"` once, then `screenshot <path>`.
   AX has a 5s worker deadline; OCR has 3s fast / 5s accurate deadlines. Accurate
   Vision stalls on the tested Xcode 27.2 host: do not retry it repeatedly.
   OCR taps require unique confident text, trying exact fast matches first and
   accurate fallback for uncertain/missing text on the same frame. An accurate timeout
   pauses automatic fallback for 60s; `see accurate` explicitly retries. Stalls leave
   coordinate input usable; cooldown never permits a lower-confidence tap.
5. Touches, AX and OCR use **points**; screenshots use **pixels**. Divide screenshot
   coordinates by `info` scale. Geometry follows active interface orientation;
   unsupported/ambiguous display geometry fails before input.
6. Verify the app outcome. Dispatch success and pixel settling do not prove it.
   `scroll down` uses touch; `drag 80 165 80 65` allows precise scrolling. `crown`
   sends native Watch Crown events; a swipe does not validate Crown behavior.

Batch known steps whose next action does not depend on an unseen result:

```sh
wand --udid <ID> batch '[["tap","40","80"],["ui","diff"]]'
# JSON can also be piped to: wand --udid <ID> batch -
```

Batches settle and stop at the first error; prior steps remain applied. Lost
replies and ambiguous input never replay automatically. Inspect before retrying.

## Lifecycle and cleanup

Xcode 27 uses one persistent host DTUHID connection, with no guest helper.
`info` identifies the transport. After interruption, inspect and `stop` the selected
daemon before retrying. Startup has a 20s total deadline and kills only its own
unready child; a timeout is not permission to replay input.

`boot` is headless; use `--show` only for visible checks. Reuse one DeviceHub window
and select devices in its sidebar. Keep the Mac unlocked; do not create windows or
reset a watch to work around a lock. Keep only needed simulators running.
Reuse one task-owned fixture for local debugging and inspect failures in place;
reserve the create/delete CI harness for cold-start qualification.
`stop` closes the daemon/workers, **not** the simulator. Shut down task-owned
throwaways afterward; preserve unrelated processes and stateful QA accounts.
Erase/delete/uninstall is not routine cleanup. Keep evidence, remove scratch images.

`cleanup --dry-run` previews inactive diagnostics; `cleanup` applies retention.
Daily startup maintenance preserves active logs, locks, recordings and user screenshots.

## Tests and optional MCP

Watch: `examples/watch/touch-smoke.swift` with an explicit disposable watch and
Settings root visible. iOS: `examples/native/e2e.sh` with explicit `WAND_UDID` and
fixture installed. Both assert actual outcomes. Coverage, budgets and limits:
`docs/validation/reliability-2026-11-10.md`, `docs/performance.md`.

`mcp --compact` exposes one `run` tool (`udid`, `commands` using batch format).
`setup --mcp` registers compact mode with Claude; `mcp` / `setup --full-mcp` retain
legacy tools. Cancellation skips queued work and later batch steps; dispatched
input may finish. Observe before resuming.
