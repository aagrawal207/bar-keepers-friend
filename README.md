# Bar Keeper's Friend

A native macOS menu bar manager — hide, organize, and reveal your status bar
icons when you have too many. In the spirit of Bartender and [Ice](https://github.com/jordanbaird/Ice),
built ground-up for macOS 26 (Tahoe).

> The name is a play on the cleaning product *Bar Keepers Friend* — it tidies up your menu bar.

## Status

Working prototype, not yet a drop-in replacement for every Bartender workflow:

- **Phase 0** — project skeleton, protocol seams, agent-app shell. ✅
- **Phase 1** — cosmetic hide/show that needs **zero permissions and zero private APIs**.
  The baseline that keeps working even if Apple changes the private menu-bar internals. ✅
- **Phase 2** — floating bar that mirrors hidden icons below the menu bar (horizontal strip
  or vertical list), so a too-narrow (notched) menu bar isn't relied on to show items.
  Clicking a mirrored icon reveals the section and triggers the real item. Needs Screen
  Recording (to capture icon images) + Accessibility (to click). ✅
- **Phase 3** — per-item **Shown / Hidden** control in Settings that physically moves the real
  item across the anchor (the Bartender-style direct picker), plus a global toggle shortcut
  (⌥⌘B). Uses private window-server behavior, so it's fenced behind a protocol seam with a
  self-validating retry loop. ✅ *(Moves were verified on-device; activation limitations remain below.)*

### Known limitations

- Activating a mirrored icon reveals the real menu-bar section and can visibly move the cursor.
  Some apps' menus still need compatibility testing.
- Cold-start glyph capture is not fully verified from boot, and a stuck native capture call can
  block later refreshes. The current queue timeout does not guarantee recovery.
- Multi-display behavior and native mouse-event changes require live hardware checks. Passing
  unit tests alone is not evidence that these paths work on every menu-bar layout.

Current work and verification details are tracked in [AGENTS.md](AGENTS.md), with the remaining
capability gaps in [PARITY.md](PARITY.md).

The Shown/Hidden path was re-verified on macOS 26.6.2 on 2026-09-11. Placement is checked against
live native control boundaries; Settings reports observed placement and errors instead of treating
a saved preference as proof that an icon moved. These checks do not establish full Bartender parity.

### How it works

The menu bar can't always fit every icon (especially around the notch), so revealed items
appear in a floating bar instead. Because a macOS status item can only be captured while
on-screen — and not at all once pushed off — the app captures each icon's image **before**
hiding it and shows the cached images in the floating bar.

## Design

The architecture isolates every fragile, OS-version-dependent capability behind a
protocol (`WindowServer`, `PermissionProbe`, …) so the bulk of the logic is pure value
types that are exhaustively unit-tested without ever launching the menu bar agent.

- **`BarKeepersFriendCore`** — pure logic: section classification, notch geometry, the
  hide/show state machine, preferences, the per-item move planner. No AppKit side effects.
- **`BarKeepersFriend`** — thin AppKit shell: `NSStatusItem` management, the settings
  window (SwiftUI), lifecycle.

See [the plan](https://github.com/aagrawal207/bar-keepers-friend) for the full roadmap.

## Why not the Mac App Store?

Menu bar managers must run **unsandboxed** and use **private window-server APIs** to
control other apps' status items. Both are automatic App Store rejections
(guidelines 2.4.5(i) and 2.5.1). Planned distribution is Developer ID signed and notarized,
outside the App Store. Current builds use an Apple Development identity and are not notarized.

## Building

Requires macOS 26+, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project BarKeepersFriend.xcodeproj -scheme BarKeepersFriend \
  -destination 'platform=macOS' build
```

Run the tests:

```sh
xcodebuild -project BarKeepersFriend.xcodeproj -scheme BarKeepersFriend \
  -destination 'platform=macOS' test
```

The suite includes pure Core tests and a hostless App-adapter target. Adapter tests measure actual
SwiftUI content off-screen and exercise cancellation with fake native dependencies, without
launching the menu-bar app, taking screenshots, or moving the mouse.
It currently contains 341 tests (432 invocations including parameterized cases).

## Credit

Ice (GPL-3.0) was studied as documentation of *which* private macOS symbols exist and
how the menu-bar mechanisms work. No Ice source code is used here; this project is an
independent, clean-room implementation under the MIT license.

## License

MIT — see [LICENSE](LICENSE).
