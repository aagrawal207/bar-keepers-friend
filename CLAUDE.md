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
- Test: same command with `test` (currently **161 tests, 19 suites**).
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
- **Per-item Shown/Hidden (private API) — VERIFIED WORKING on-device 2026-06-28.** Settings → Items
  lists every manageable item with a Shown/Hidden segmented control; flipping it **physically
  moves** the real item across the anchor. The move uses Ice's two-tap "scromble" relay (a direct
  `.cgSessionEventTap` post is INERT on Tahoe — it relocated 0/12; the relay routes each event to
  the item's owning process and relocated 17/24, the failures being genuinely-immovable transient
  windows). Three things had to be right: (1) the scromble relay (`scrombleEvent` in
  `SystemWindowServer.swift`); (2) `reconcile` attributes snapshots first so the relay targets the
  REAL owning pid, not Tahoe's broken Control-Center pid; (3) the launch reconcile guard checks
  `floatingBar.isVisible`, not the broader `sectionInUse` (which is always true at launch, so the
  old guard skipped the move every time). **Only moves items the user explicitly toggled** —
  `ItemControlStore` tracks `hiddenInMenuBar` + `shownInMenuBar`; an un-configured item has no
  intent and is left exactly where it sits (hiding one item never rearranges the rest). Pure
  `HiddenLayoutPlanner` decides moves; tested against `FakeWindowServer` (161 tests).
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
- **Hide All / Show All** — bulk buttons in the Items header flip every item's intent in ONE
  mutation (single reconcile, persisted once), each disabled when it'd be a no-op. Backed by
  `SettingsModel.setHidden(_:forAll:)` + tested store semantics.

## Removed (intentionally — don't re-add without asking)

- **Search panel** + its ⌥⌘F hotkey — user found it confusing.
- **"Show section dividers"** toggle — divider is now an invisible mechanism only.
- **Reveal-on-hover** — user didn't want it (and the off-switch didn't fully stop it).

## Remaining work

### Bugs (open)

- **[MEDIUM] A few items still won't move (transient/system windows).** After the scromble fix the
  reconcile relocates the large majority (17/24 in the verification run), but some fail: notably
  `Karabiner-NotificationWindow` (a transient notification window that lives at the status layer
  but isn't a real movable status item), Xcode, and the odd Control Center module. The planner
  should pre-filter these (broaden `ImmovableItems` / skip non-status transient windows) so it
  doesn't attempt+fail+retry on them — each failed item burns 5 retries (~1s) and a `wakeUp` click.
- **[LOW] Cursor moves during a multi-item reconcile.** With the move now succeeding on attempt 1,
  a single toggle is near-instant, but a large multi-item reconcile (or one with stubborn items
  that retry) still warps the cursor per move via the `defer` in `SystemWindowServer.move`. A
  batch-scoped cursor guard (disassociate + hide + ONE warp-back around the whole reconcile,
  keeping `.cgSessionEventTap`; `postToPid` ruled out as unsafe) would smooth it. Lower priority
  now that moves don't burn 5 failed retries each. Design is in memory `bkf-private-api-direction`.
- **[RESOLVED 2026-06-28] The synthesized per-item move failed 100% (0/12).** Root cause: a direct
  `.cgSessionEventTap` post is inert against another app's status item on Tahoe; plus reconcile fed
  the move the broken Control-Center pid; plus the launch guard always skipped. Fixed via the
  scromble relay + attribution-in-reconcile + the `floatingBar.isVisible` guard. Verified 17/24
  on-device (see Built). Kept as a note: if a future OS breaks it again, the symptom is `ok=0`.
- **[RESOLVED 2026-06-28] Wisp mislabeled "Control Center" in the Items tab.** A fresh
  `BKF-diag.json` attributes all 6 items correctly (Wisp, Neru, Amazon Persist, Karabiner-Menu,
  Hammerspoon, ACME); `BKF-bar.png` confirms it. Kept as a note in case it regresses on a different
  menu-bar layout.

### Needs hardware verification (can't be done from an agent — Xcode holds the app)

- **AXPress activation failure** — items advertise `AXPress` but it returns a non-success error;
  why is open (error-code logging was added). Synthesized click is the working default.

### Features not yet built (from the plan, roughly prioritized)

- **Per-item / global hotkeys** to toggle a *specific* item. (Deferred until the synthesized move
  is hardware-verified — don't keep building on an unproven mechanism.)
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
