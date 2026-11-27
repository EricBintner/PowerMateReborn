# Release v1.2.3 — Bluetooth and Crash Fixes

**Status: PUBLISHED 2026-11-27** — build 202611270615, notarized, tag `v1.2.3`, appcast live. Bluetooth changes still unconfirmed on hardware; results are tracked in issue #4.

Follows the [v1.2.0 runbook](RELEASE_v1.2.0.md) (build → verify → tag → GitHub release → appcast). Notarization uses the `PowerMate-Notarization2` keychain profile (`scripts/build-dmg.sh` default).

Fixes issue #4 (duplicates #2, #3, #5): the Bluetooth knob connected and disconnected in a loop on v1.2.0 to v1.2.2. Also fixes the crash in issue #5's log (About and Quick Start, see [RELEASE_PITFALLS.md](RELEASE_PITFALLS.md) Part 2 item 10) and the gaps in Report Issue that those reports showed.

**The Bluetooth changes are untested on hardware.** The maintainer only has the USB knob. They are built from the LightBlue capture in issue #4 and public descriptions of the protocol, and are covered by unit tests of the protocol logic, not by a real knob. The release notes say so.

Values for the runbook: tag `v1.2.3`, release title `PowerMateReborn v1.2.3: Bluetooth and Crash Fixes`, DMG `build/PowerMateReborn_v1.2.3.dmg`, tag message `Bluetooth reconnect loop and event decoding, About and Quick Start crash, issue report fixes`.

## Extra checks for this release

Before Phase 2 (build):

```bash
swift test        # expect 94 tests, 0 failures
```

In the Phase 3 smoke test, on top of the usual list:

- **About… and Quick Start… open, with the logo and the knob picture.** This is the crash fix. Testing it on this Mac is meaningful now: the lookup no longer falls back to the `.build` folder.
- **USB gestures still work:** turn, tap, double-tap, long press. The gesture code in `PowerMateManager` was split so Bluetooth can share it.
- **Report Issue…:** the whole form is visible. Open GitHub Issue stays disabled until there is a title, a description and a knob choice. The system information shows `USB knob: connected` and a `Bluetooth knob:` line. Copy Report, paste it somewhere, and check that each section appears once and no home folder path appears.
- **The log** (`~/Library/Application Support/PowerMateReborn/PowerMateReborn.log`) has a `Launch: PowerMateReborn 1.2.3` line and `USB: PowerMate connected`.

Not checkable here: anything on a Bluetooth knob, and whether the standing reconnect request for a remembered knob affects Mac sleep. A Mac that has never had a Bluetooth knob working makes no such request.

## Release notes (paste into the GitHub release)

```markdown
## PowerMateReborn 1.2.3 — Bluetooth and Crash Fixes

> **Bluetooth is untested on real hardware.** I only own the USB PowerMate. The Bluetooth changes below are built from a user's capture and published descriptions of the knob's protocol. Treat them as theoretical until confirmed, and please report results in #4.

- **Fixed: the Bluetooth PowerMate connected and disconnected in a loop.** 1.2.0 to 1.2.2 dropped a working knob right after connecting, then found it again and repeated.
- **Fixed: Bluetooth turns and presses were misread.** The knob sends an event code for each turn, click and hold. Earlier versions read those as step counts and read the battery level as the button. The LED now uses the knob's own brightness codes.
- **A Bluetooth knob that has connected is remembered** and reconnects when it wakes, without waiting for a scan.
- **Fixed: the About and Quick Start windows quit the app when opened.** This affected every Mac except the one the app was built on, in every release so far.
- **Report Issue is more useful.** It asks which PowerMate you have, needs a title and a description, reports USB and Bluetooth status separately, and no longer repeats sections when you paste. Your account name, your own name and your home folder are removed from the report.

**Bluetooth differences from USB:** long press fires after about one second (the Long Press Threshold setting applies to USB only), and double-tap is not available yet.

**Requirements:** macOS 13+ on an Apple silicon Mac.
```

## Appcast item (add above the v1.2.2 item when publishing)

Fill in the four placeholders from the Phase 2 output, as in the runbook.

```xml
    <item>
      <title>Version 1.2.3 (Bluetooth and Crash Fixes)</title>
      <description><![CDATA[
        <h2>What's new</h2>
        <ul>
          <li><b>Bluetooth is untested on real hardware.</b> The maintainer only owns the USB PowerMate. The Bluetooth changes are built from a user's capture and the knob's published protocol.</li>
          <li><b>Fixed: the Bluetooth PowerMate connected and disconnected in a loop.</b> 1.2.0 to 1.2.2 dropped a working knob right after connecting.</li>
          <li><b>Fixed: Bluetooth turns and presses were misread.</b> A knob that has connected is also remembered and reconnects when it wakes.</li>
          <li><b>Fixed: the About and Quick Start windows quit the app when opened.</b></li>
          <li><b>Report Issue is more useful.</b> It asks which PowerMate you have, needs a title and a description, and removes your name and home folder from the report.</li>
        </ul>
      ]]></description>
      <pubDate>RFC_2822_DATE_HERE</pubDate>
      <sparkle:version>BUILD_NUMBER_HERE</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/EricBintner/PowerMateReborn/releases/download/v1.2.3/PowerMateReborn_v1.2.3.dmg"
        length="FILE_SIZE_BYTES"
        type="application/octet-stream"
        sparkle:edSignature="EDDSA_SIGNATURE"
      />
    </item>
```

## After publishing: comment on issue #4

The reply on issue #4 promised a comment when the build is available. Post this once the release and the appcast are live.

```markdown
v1.2.3 is available: https://github.com/EricBintner/PowerMateReborn/releases/tag/v1.2.3

**Untested:** this build has not been run on a real Bluetooth PowerMate. I only own the USB model, so the Bluetooth changes are still theoretical until someone confirms them here.

**Before testing**

- Quit LightBlue and any other app connected to the knob. The knob cannot be found while another app holds the connection.
- Launch PowerMateReborn, then turn or press the knob within the first minute to wake it. The first connection relies on a scan.

**Test steps**

1. Turn the knob both ways. The level should move one step per click, in the right direction.
2. Tap once. In Volume mode the volume should snap to 20%, or back, after a short pause.
3. Hold the button for two seconds. The mode should change once, after about one second.
4. Press and turn. The level should change, the mode should not, and no tap should fire when you let go.
5. Note whether the LED lights and follows the level.
6. Leave the knob idle for 15 minutes, then turn it. Note how many seconds it takes to respond.
7. Leave the Mac alone with the app running and check that it still goes to sleep on its own.

**Reporting**

- Open Report Issue… and click Copy Report, then paste the result as a comment here, whether the steps passed or failed.
- For anything that failed, say which step and what happened instead.
- The log records the raw bytes the knob sends, which is what I need to correct the decoding.

**Known limits on Bluetooth**

- Long press fires after about one second. The Long Press Threshold setting applies to USB only.
- Double-tap is not available yet.
```
