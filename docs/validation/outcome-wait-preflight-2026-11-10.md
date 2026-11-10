# Expected-state waiting: watch preflight — 2026-11-10

**Not qualified; no runtime change shipped.** Before implementing faster expected-
state settling, tested whether the existing watch fixture exposes a state that
can distinguish the destination screen. It does not.

On disposable 40mm watch `48B1CAAD-E31C-4E3D-BF36-2F8665006E89`, watchOS 27.2,
the full accessibility tree was byte-identical on Settings root, Notifications,
and after returning to Settings:

```text
1 elements (full tree)
e1 Application "Settings" @81,99
```

Screenshots independently show the transitions. See
[Settings](outcome-wait-preflight-2026-11-10/settings-root.png),
[Notifications](outcome-wait-preflight-2026-11-10/notifications.png), and
[returned Settings](outcome-wait-preflight-2026-11-10/returned.png).
Raw observations and command timing are in the adjoining evidence directory.

An application-level match would be true before and after the tap. Treating it as
destination readiness would create a false success; a child selector would never
appear in this tree. The existing one-second watch settling floor is therefore
unchanged. No fake success, blanket shorter sleep, OCR loop or input replay was
introduced.

This was a prerequisite check, not the proposed performance qualification. The
20% action-latency improvement and zero incorrect transitions across 100 actions
were **not demonstrated**. Two baseline navigation actions succeeded, taking
1,523 and 1,278 ms; two samples do not establish a latency distribution.

A future candidate needs a fixture with reliable, distinct destination state,
then interleaved baseline/candidate timings and real transition assertions.
Other accessibility implementations may expose more; this result does not prove
that expected-state waiting is impossible on every platform. Cold iOS setup
qualification remains deferred as previously agreed.

The watch's available Keychain data was backed up before boot to
`~/wand-outcome-40mm-backup-20261110-163743.tgz` (120,251 bytes). No Belly data
containers were present in that disposable device's application-container scan.
Production QA watch `B0CDF864` remained shut down and untouched. After the check,
the task daemon was stopped and the disposable watch shut down; zero simulators
remained booted. Scratch screenshots were removed after preserving this evidence.
