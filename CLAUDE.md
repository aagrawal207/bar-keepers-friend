# CLAUDE.md — Bar Keeper's Friend

Context for Claude Code sessions working on this repo. This file is the running source of
truth for **what's built, what's left, and what's broken**. Keep it current.

## What this is

A native macOS **Tahoe (26) only** menu bar manager (like Bartender / Ice): hide, organize,
and reveal status bar icons. MIT, clean-room (Ice studied for mechanism only, no code copied).
Public repo `aagrawal207/bar-keepers-friend`; commits use the GitHub noreply email, never the
Amazon address.

User's bar: **flawless, very well tested**, effort no object. Default to removing confusing
options over adding power-user knobs.

## Architecture (the seam is the point)

Every OS-touching capability sits behind a protocol so the fragile parts are mockable and the
pure logic (~70%) is unit-tested without launching the app.

- **`BarKeepersFriendCore`** (static lib) — pure value types + logic. No AppKit. Swift Testing.
  Hide/show state machine, layout math, notch geometry, planners, persistence, attribution
  matcher. This is where most logic lives and where new logic should go.
- **App target** (`LSUIElement` agent app) — AppKit/SwiftUI shell that wires Core to the OS:
  status items, the floating bar panel, capture, the synthesized move, settings.
- **`WindowServer` protocol** is the single seam to the fragile/private window-server surface;
  `FakeWindowServer` backs the tests, `SystemWindowServer` is the real impl.

## Build / test / run

- Generate project after adding/removing files: `xcodegen generate` (the `.xcodeproj` is
  gitignored — `project.yml` is the source of truth).
- Build: `xcodebuild -project BarKeepersFriend.xcodeproj -scheme BarKeepersFriend -destination 'platform=macOS' build`
- Test: same command with `test` (currently **145 tests, 19 suites**).
- Sign: stable Apple Development identity by SHA-1 (in `project.yml`) so granted TCC
  permissions persist across rebuilds. Never ad-hoc (`-`) — it re-prompts every launch.
- All git on this Mac needs `-c core.hooksPath=/dev/null` (git-defender). Never `git push`
  unless asked; never force-push / rewrite pushed history. Main branch: `main`.

### Running + observing (no Xcode in the loop)

Run the app **standalone**, not via Xcode Run — an Xcode-launched process is parented to
`debugserver`, sits in state `SX`, and **cannot be `pkill`ed or signalled**; only Xcode's Stop
(⌘.) clears it. A standalone launch is parented to `launchd`, state `S`.

- Launch: `open <DerivedData>/.../Debug/BarKeepersFriend.app`
- **Diagnostics (`kill -USR1 <pid>`):** refreshes the mirror, then writes
  `~/Library/Logs/BKF-diag.json` (deep AX dump + attribution per item) and
  `~/Library/Logs/BKF-bar.png` (rendered panel). Async + deep AX inspect — wait ~12–16s, don't
  `rm` around it. The PNG is how to *see* what the user sees.
- `kill -USR2 <pid>` toggles the bar (for screenshotting).
- `BKF_DUMP_CROPS=1` (launch the binary directly, not via `open`) dumps raw pre-keying crops.
- Runtime log: `~/Library/Logs/BarKeepersFriend.log`.

## Built (done)

- **Cosmetic hide/show** — own anchor + (now invisible) divider `NSStatusItem`; expanding the
  divider's length pushes items left of the anchor off-screen. Zero permissions, zero private
  APIs — the unbreakable baseline. Divider width bounded `[500, 4000]` (never literal 10000).
- **Floating bar** — mirrors hidden (left-of-anchor) items in a panel below the menu bar
  (horizontal strip / vertical list). Captures each icon's image while on-screen (off-screen
  items can't be captured), caches it, shows from cache. Monotonic cache + two-pass warm-up so
  first load is clean. Slide+fade animation, Reduce-Motion aware. Needs Screen Recording.
- **Activate a mirrored item** — reveal section → synthesized CGEvent click → leave revealed so
  the menu opens. Cursor hidden during the click. Needs Accessibility.
- **Per-item Shown/Hidden** (private API) — Settings → Items lists every manageable item with a
  Shown/Hidden segmented control; flipping it **physically moves** the real item across the
  anchor (synthesized ⌘-mouseDown off-screen + mouseUp at destination, windowID stamped into
  CGEvent fields 91/92/0x33, posted via `.cgSessionEventTap`). Self-validating: 5 retries +
  frame-change confirmation + wake-up nudge. Pure `HiddenLayoutPlanner` decides moves;
  `HiddenItemController` performs them; engine reconciles inside its on-screen reveal sequence.
- **Global toggle hotkey** — ⌥⌘B via Carbon `RegisterEventHotKey` (no Accessibility prompt).
  Keyboard-opened bar persists until re-toggled (doesn't auto-dismiss).
- **Auto re-hide**, **dismiss-on-mouse-exit** (gated on the pointer having first entered the
  panel, so a revealed bar doesn't vanish instantly), **launch at login**, **layout
  export/import** (versioned JSON), **per-item display aliases** (nicknames in the bar/Items
  list), **multi-display** anchor placement, **notch-safe** geometry.
- **Permissions panel** — Settings → General shows live Accessibility + Screen Recording status
  (Granted / Needs re-approval / Not granted), explains what each unlocks, and offers an "Open
  Settings…" button per permission. Polls while open so a freshly-granted permission updates
  without reopening. Both are optional (the cosmetic baseline needs neither), so it never blocks.
  Pure `PermissionState` machine in Core + `SystemPermissionProbe` in the app target.
- **Floating bar grid wrapping** — a large hidden set no longer overflows the screen. `Floating-
  BarLayout` computes a screen-fitted items-per-line and wraps into a grid (horizontal → extra
  rows; vertical → extra columns); `FloatingBarView` renders the matching grid. Pure + tested
  (panel never exceeds the display at 80 items either axis). *(grid rendering not yet
  hardware-verified, but the geometry is.)*
- **Items list grouped Hidden / Shown** — Settings → Items splits into "Hidden (N)" and
  "Shown (N)" sections instead of one interleaved list, so the two states scan at a glance and a
  toggled row visibly moves between them (cheap re-partition, no menu-bar re-scan). Pure
  `ItemControlStore.partitionByHidden` + tested.

## Removed (intentionally — don't re-add without asking)

- **Search panel** + its ⌥⌘F hotkey — user found it confusing.
- **"Show section dividers"** toggle — divider is now an invisible mechanism only.
- **Reveal-on-hover** — user didn't want it (and the off-switch didn't fully stop it).

## Remaining work

### Bugs (open)

- **[HIGH] Wisp (and possibly other right-of-anchor items) mislabel as "Control Center" in the
  Items tab.** The new `allManageableItems()` enumerates items on *both* sides of the anchor;
  near Control Center's module cluster, an item's window can match a Control Center AX extra by
  position (or Wisp doesn't answer the AX sweep that pass and falls back to the broken Tahoe
  owner = Control Center, FB18327911). NOTE: diagnostics show Wisp attributes *correctly* when
  hidden, so this is specific to the both-sides picker path. **Do NOT blind-fix** — a wrong
  guard could make Wisp vanish from the picker. Needs a live `BKF-diag.json` from the *current*
  build (Wisp's frame + which extra it matched). See `AXAttributionProvider` + `MenuBarExtraMatcher`.

### Needs hardware verification (can't be done from an agent — Xcode holds the app)

- **The synthesized per-item move actually relocating a live item.** All orchestration is tested
  against `FakeWindowServer`; the CGEvent code compiles against the real SDK; but whether the
  drag moves a real item is unverified. Research flagged it goes intermittent on Tahoe (unstick:
  `killall ControlCenter`). If flaky, escalate to Ice's fuller pid↔session "scromble" event
  routing (deliberately omitted from v1 as the most complex, single-sourced part).
- **AXPress activation failure** — items advertise `AXPress` but it returns a non-success error;
  why is open (error-code logging was added). Synthesized click is the working default.

### Features not yet built (from the plan, roughly prioritized)

- **Per-item / global hotkeys** to toggle a *specific* item.
- **Triggers / automation** — battery / wifi / app-active / schedule → apply a preset.
- **Presets / profiles** — saved arrangements, per-display or per-Space.
- **Always-Hidden tier** — a second section never shown in the bar (deferred; Tahoe broke nested
  sectioning for Ice, so approach with care).
- **Menu-bar item spacing** (global `NSStatusItemSpacing`) — opt-in, force-relaunches every
  menu-bar app; ship only with a clear warning + reset.
- **First-run onboarding** — a guided welcome flow (the Permissions *panel* in Settings is done;
  what's left is a proactive first-launch walkthrough rather than the user finding Settings).
- **Sparkle auto-update**, **notarized DMG** distribution.

## Hard constraints / gotchas

- **macOS 26 only.** `kCGWindowOwnerPID` is broken (FB18327911 — everything reports as Control
  Center), so owner attribution is by frame-matching AX extras, not PID.
- The synthesized move and capture are the fragile bits — keep them behind `WindowServer` /
  `IconCaptureService` with graceful fallback, never let them crash the permission-free baseline.
- Don't `pkill` an Xcode-launched instance (state `SX`); ask the user to press Stop.
- Keep this file current: when you finish a feature move it to **Built**, when you find a bug add
  it under **Bugs**, when you remove something note it under **Removed**.
