# Release v1.2.2 — Mute and Issue Report Fixes

**Status: PUBLISHED 2026-10-19** — build 202610191217, notarized, tag `v1.2.2`, appcast live.

Follows the [v1.2.0 runbook](RELEASE_v1.2.0.md) (build → verify → tag → GitHub release → appcast). Notarization uses the `PowerMate-Notarization2` keychain profile (`scripts/build-dmg.sh` default).

Fixes a user report (macOS 26.7.1, Mac mini M2 Pro, Dayton Audio M4 USB speakers): the knob didn't unmute after a keyboard mute, 0% wasn't fully silent, and Report Issue failed with "Malformed request".

## Release notes (paste into the GitHub release)

```markdown
## PowerMateReborn 1.2.2 — Mute and Issue Report Fixes

- **Fixed: the knob didn't unmute after muting with the keyboard.** After F10 (mute), or F11 all the way down, turning the knob changed the volume silently while the on-screen indicator stayed on the muted symbol. Turning the knob now unmutes, like the volume slider in Control Center.
- **Fixed: 0% wasn't completely silent on some USB speakers.** Turning the knob down to 0% now mutes the output, the same as the keyboard's volume keys.
- **Fixed: Report Issue opened a "Malformed request" page.** GitHub rejected the pre-filled issue because of the attached logs. Report Issue now copies the full report, logs included, to your clipboard and opens the issue with your description and system info filled in, so you just paste.
- `+` signs in issue reports no longer turn into spaces.

**Requirements:** macOS 13+ on an Apple silicon Mac.
```
