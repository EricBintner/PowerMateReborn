# Release v1.2.1 — Display Sleep Fix

**Status: PUBLISHED 2026-10-18** — build 202610182329, notarized, tag `v1.2.1`, appcast live.

Follows the [v1.2.0 runbook](RELEASE_v1.2.0.md) (build → verify → tag → GitHub release → appcast). Notarization uses the `PowerMate-Notarization2` keychain profile (`scripts/build-dmg.sh` default).

Root cause and measurements: [.bug-hunt/TESTING.md](../.bug-hunt/TESTING.md) item 4 and [RELEASE_PITFALLS.md](RELEASE_PITFALLS.md) Part 3 item 1.

## Release notes (paste into the GitHub release)

```markdown
## PowerMateReborn 1.2.1 — Display Sleep Fix

- **Fixed: the USB PowerMate could keep your displays from ever going to sleep.** macOS read the knob's LED status as a media key held down, so it saw constant activity and never let the screens idle off. PowerMateReborn now takes exclusive control of the knob while it's running, so macOS no longer misreads it.
- Turning or pressing the knob still counts as activity, like moving the mouse: it wakes the screens and postpones display sleep.
- If you use the knob while PowerMateReborn isn't running, it may keep the displays awake again until the app is relaunched.

**Requirements:** macOS 13+ on an Apple silicon Mac.
```
