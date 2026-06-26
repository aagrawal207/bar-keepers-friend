# Bar Keeper's Friend

A native macOS menu bar manager — hide, organize, reveal, and search your status bar
icons when you have too many. In the spirit of Bartender and [Ice](https://github.com/jordanbaird/Ice),
built ground-up for macOS 26 (Tahoe).

> The name is a play on the cleaning product *Bar Keepers Friend* — it tidies up your menu bar.

## Status

Early development. Built in phases, robust core first:

- **Phase 0** — project skeleton, protocol seams, agent-app shell. *(in progress)*
- **Phase 1** — cosmetic hide/show that needs **zero permissions and zero private APIs**.
  This is the baseline that keeps working even if Apple changes the private menu-bar internals.
- **Phase 2+** — per-item control, search, and a notch-overflow bar (these require
  Accessibility / Screen Recording permissions and private window-server APIs).

## Design

The architecture isolates every fragile, OS-version-dependent capability behind a
protocol (`WindowServer`, `PermissionProbe`, …) so the bulk of the logic is pure value
types that are exhaustively unit-tested without ever launching the menu bar agent.

- **`BarKeepersFriendCore`** — pure logic: section classification, notch geometry, the
  hide/show state machine, preferences, search ranking. No AppKit side effects.
- **`BarKeepersFriend`** — thin AppKit shell: `NSStatusItem` management, the settings
  window (SwiftUI), lifecycle.

See [the plan](https://github.com/aagrawal207/bar-keepers-friend) for the full roadmap.

## Why not the Mac App Store?

Menu bar managers must run **unsandboxed** and use **private window-server APIs** to
control other apps' status items. Both are automatic App Store rejections
(guidelines 2.4.5(i) and 2.5.1). Distribution is Developer ID signed + notarized,
outside the App Store — the same path Ice and Bartender take.

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

## Credit

Ice (GPL-3.0) was studied as documentation of *which* private macOS symbols exist and
how the menu-bar mechanisms work. No Ice source code is used here; this project is an
independent, clean-room implementation under the MIT license.

## License

MIT — see [LICENSE](LICENSE).
