# Bar Keeper's Friend

A native menu bar manager for **macOS 26 (Tahoe)**. Keep everyday icons visible, tuck away
the rest, and bring them back with a click or **Option-Command-B (⌥⌘B)**.

Hidden icons appear in a floating bar below the menu bar, with a horizontal strip or vertical
list to choose from. Click an icon there to open its real menu. You can also reveal hidden
items in the menu bar itself.

**Try it:** [build from source](#build-from-source). As of September 15, 2026, there are
**no published [GitHub releases](https://github.com/aagrawal207/bar-keepers-friend/releases)**
or ready-to-install app/DMG downloads. The app is under active development; see
[known limitations](#known-limitations) before relying on it for every menu-bar workflow.

## Everyday use

BKF lives in the **menu bar**, with no Dock icon. Right-click (or Control-click) its icon to
open **Settings**, **Pause**, **Restart**, **Check for Updates**, or **Quit**.

### Hide or unhide an item

1. Open **Settings > Items**.
2. Choose **Shown**, **Hidden**, or **Always Hidden** for the items you want to change:
   - **Shown** keeps the icon in the normal menu bar.
   - **Hidden** tucks it away until you open BKF.
   - **Always Hidden** keeps it out of ordinary reveals; Option-click includes it.
3. Review the **Menu Bar** and **Hidden Bar/List** previews.
4. Choose **Apply Changes** to save your choices and move the real items. Choose **Discard**
   to abandon the unapplied placement edits.
5. Click the BKF icon or press **⌥⌘B** to reveal hidden icons; repeat to close the bar.
   To restore an icon permanently, select **Shown** and **Apply Changes**.

**Hide All / Show All** use the same draft and require Apply Changes. Previews use cached
images: **After Apply** shows your proposed arrangement and **Last Observed** shows the latest
loaded placement. They are schematics, not live screenshots or exact spacing previews.
If a move fails, Settings shows the failure and offers **Retry**.

Placement drafts survive closing Settings within the current session, but not an app restart.
Item nicknames save separately on Return or when you leave the field; Discard does not undo them.

### Reveal controls

| Action | Result |
| --- | --- |
| Click BKF | Open or close the hidden bar. |
| **⌥⌘B** | Toggle the bar. A keyboard-opened bar stays open until you toggle it again or interact with it. |
| **Option-click BKF**, with the bar closed | Include Always Hidden items in the reveal. |
| Click a mirrored icon | Reveal its real menu-bar item and activate it; requires Accessibility. |
| **Pause** in the right-click menu | Reveal items in place and suspend automated hiding, revealing, and moving. Select Pause again to resume. |

**Settings > Behavior** controls automatic re-hide, floating-bar layout, and optional hover
or scroll/swipe reveal. Hover defaults off; leaving closes only a hover-opened bar. Pause is
session-only. **Settings > Shortcuts** lets you change the toggle shortcut and assign item shortcuts.

### Permissions and first launch

Open **Settings > General > Permissions** to review access and use **Open Settings…** to
reach the corresponding macOS **Privacy & Security** pane.

| Permission | What it enables |
| --- | --- |
| None | Basic hide/reveal of the existing hidden section in the menu bar. |
| **Screen Recording** | Capture the actual menu-bar glyphs for the floating bar. macOS may label this pane **Screen & System Audio Recording**. |
| **Accessibility** | Identify and move other apps' items for Apply Changes, and activate them from the floating bar. |

Both permissions are optional. For basic in-place hide/reveal, turn off **Show hidden items
in a floating bar** in **Behavior**. After granting access, follow any macOS request to quit
and reopen BKF. **Needs re-approval** means macOS no longer recognizes a previously granted permission.

Icon capture currently takes a **whole-display image**, crops the icons locally, and caches
the glyphs. Opening the floating bar uses the cache and does not start a new screen capture.

**Seeing app icons instead of menu-bar glyphs?** On first launch, BKF may show app-icon
fallbacks until it can capture real glyphs. A fullscreen Space or an auto-hidden menu bar can
prevent that capture. Switch to a normal desktop with the menu bar visible, close the floating
bar, and give the delayed refresh a few seconds. Check Screen Recording access if fallbacks
persist. Remembered glyphs help on later launches, but freshness at every open is not guaranteed.

### Find a setting

The everyday pages are **General**, **Items**, **Style**, **Behavior**, and **Shortcuts**.
**Advanced** holds presets, triggers, groups, and infrequent system-wide options.
**About** contains version and project information.

Use the sidebar's **Search Settings** field to find a page or setting. Selecting a result
briefly highlights the destination; a hidden control points to its enabling switch.
**Style > Icons** changes BKF's menu-bar symbol and its artwork in Settings, About, and alerts.
The installed Finder icon stays the same.

For upgrades from earlier source builds: widgets have been removed from the UI and runtime.
Legacy saved widget data is retained for compatibility but remains inactive.

## Build from source

### Requirements

- **macOS 26 (Tahoe)**. Other major macOS versions are not supported.
- **Full Xcode 26+**, including a macOS 26 or newer SDK. Command Line Tools alone are not
  enough. Open Xcode once to finish its license and component setup.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**. If you use Homebrew, install it with
  `brew install xcodegen`.
- **Your own Apple Development signing identity**, including its matching private key in
  your keychain. In Xcode Settings, add your Apple Account, select your team, and use
  **Manage Certificates** to create one if needed. See Apple's
  [certificate types](https://developer.apple.com/help/account/certificates/certificates-overview/).

### 1. Get the source and select Xcode

Run these commands in Terminal. Keep subsequent commands in the repository directory and
the same shell session. Adjust `DEVELOPER_DIR` if your full Xcode app is installed elsewhere.

```sh
git clone https://github.com/aagrawal207/bar-keepers-friend.git
cd bar-keepers-friend
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
xcodebuild -version
xcodegen --version
```

### 2. Select your signing identity

The repository's [project.yml](project.yml) pins the maintainer's certificate, which will
not exist on your Mac. **Override it for both build and test** using your own identity:

```sh
security find-identity -v -p codesigning
export BKF_SIGNING_IDENTITY="YOUR_APPLE_DEVELOPMENT_CERTIFICATE_SHA1"
```

Replace the placeholder with the 40-character hexadecimal hash beside your **Apple Development**
identity in the command output. This is the certificate hash, not your Team ID. If no valid
identity appears, finish the certificate setup in Xcode first.

These local builds use manual signing without a provisioning profile. Reuse a stable identity
across rebuilds to help macOS retain your permission grants; switching identities can require
re-approval. An Apple Development build is for local use and is not a notarized distribution build.

### 3. Generate, build, and launch

```sh
xcodegen generate
xcodebuild \
  -project BarKeepersFriend.xcodeproj \
  -scheme BarKeepersFriend \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$BKF_SIGNING_IDENTITY" \
  build
```

After a successful build, quit any existing BKF instance and launch the app **standalone**:

```sh
open "$PWD/DerivedData/Build/Products/Debug/BarKeepersFriend.app"
```

If you previously launched it with Xcode Run, use **Xcode Stop** before opening the standalone
copy. The generated `.xcodeproj` and `DerivedData/` are ignored by Git; regenerate the project
after source files are added or removed. Keep supplying your signing override on later builds.

To reclaim build space, quit BKF before deleting `DerivedData/`: that folder contains the runnable
app as well as build caches. The next build recreates it.

### Run the tests

From the same directory and shell session:

```sh
xcodebuild \
  -project BarKeepersFriend.xcodeproj \
  -scheme BarKeepersFriend \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$BKF_SIGNING_IDENTITY" \
  test
```

Tests cover pure Core logic and off-screen AppKit/SwiftUI workflows using real models and
isolated preferences, with native capture and input replaced by fakes. They do not launch
the menu-bar agent, capture your desktop, or move your cursor. Recorded results and hardware
verification gaps live in [PARITY.md](PARITY.md).

## Known limitations

- Per-item moves have native verification for specific apps on the built-in display.
  External-display placement failures remain open; this is not verified Bartender parity.
- Activating a mirrored icon reveals the real menu-bar section and uses positioned input.
  Complete absence of cursor flicker and compatibility with every app's menu are unverified.
- Cold-boot and external-display icon capture still need testing. A non-returning native call
  can block later work; the queue timeout does not guarantee recovery.
- Several features have automated coverage but still need live checks, including hover focus,
  Always Hidden placement, presets/triggers/groups, styling, spacing, and notch make-room.
- Styles and presets apply across displays; per-Space/per-display choices and automatic
  updates are not yet available. Settings search does not search menu-bar items.

See [PARITY.md](PARITY.md) for capability-by-capability evidence and [AGENTS.md](AGENTS.md)
for the detailed bug backlog and development constraints.

## Distribution and the Mac App Store

**The current architecture is incompatible with Mac App Store requirements.** The app is
unsandboxed (`com.apple.security.app-sandbox = false`) and uses private WindowServer/SkyLight
APIs. Apple's current App Review Guidelines require:

- **[2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements):**
  “Apps may only use public APIs”.
- **[2.4.5(i)](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility):**
  Mac App Store apps “must be appropriately sandboxed”.

A future Mac App Store edition would need a redesign around supported public APIs and App
Sandbox restrictions, potentially with a different feature set. Its eligibility would need
to be evaluated against Apple's requirements at submission time.

**Developer ID-signed, notarized direct distribution** is the realistic planned route for
this edition. It still needs release signing, Hardened Runtime validation, notarization, and
installer work. Apple's [Developer ID distribution guide](https://developer.apple.com/developer-id/)
describes that process. The source-build instructions above produce a local development app.

## Feedback and contributing

Report problems or suggest improvements in
[GitHub Issues](https://github.com/aagrawal207/bar-keepers-friend/issues). Include your macOS
version, BKF version or commit, affected app, display arrangement, fullscreen/auto-hide state,
permission status, and steps to reproduce. A relevant excerpt from
`~/Library/Logs/BarKeepersFriend.log` can help explain a failed move or capture.

For code contributions, start with [AGENTS.md](AGENTS.md). `Sources/Core` holds pure logic;
`Sources/App` holds AppKit/SwiftUI integration. `WindowServer` and the capture/permission
adapters isolate OS-dependent behavior. Changes to native movement or capture need on-device
evidence in addition to automated tests.

## Credit

In the spirit of Bartender and [Ice](https://github.com/jordanbaird/Ice). Ice (GPL-3.0) was
studied to understand the menu-bar mechanisms; no Ice source code is used here. This is an
independent, clean-room implementation. The name is a play on the cleaning product
*Bar Keepers Friend*: it tidies up your menu bar.

## License

MIT — see [LICENSE](LICENSE).
