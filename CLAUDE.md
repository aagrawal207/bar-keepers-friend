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

## Loop charter (read first if you are an automated loop fire)

A recurring task fires here every ~30 min ("build the next feature or fix a critical bug, keep
CLAUDE.md current"). The app is now in good shape; the easy, safe, high-value backlog is draining.
That changes the risk: a prompt that says *do something every 30 minutes* eventually pressures you
to invent work, chase phantoms, or touch fragile unverifiable paths just to have shipped something.
**Don't.** The real goal is not "ship a change every fire" — it is **leave the app at least as good
as you found it.** Doing nothing and reporting is a first-class, encouraged outcome.

### Pre-flight gate — a candidate must clear ALL THREE before you start work
1. **Real.** Reproduce the bug or trace its reachability in the actual code first. Don't fix what a
   log line or a hunch *suggests* — confirm it exists. (We once nearly "fixed" a capture-storm loop
   that didn't exist; a 40s probe showed zero events. There is no periodic capture loop.)
2. **Verifiable from this rig.** Either pure Core logic covered by Swift Testing, or a change whose
   correctness you can prove without seeing the menu bar. This machine **cannot** see the bar
   (`screencapture` of the strip returns black) and **cannot** signal an Xcode-launched instance.
   Anything provable only on-device goes to "Needs hardware verification" — never ship it blind.
3. **Low blast radius.** Prefer pure Core behind an existing seam. Be very cautious touching the
   capture / synthesized-move / floating-bar paths or the permission-free cosmetic baseline.

If no candidate clears all three, the correct turn is a one-line status ("no safe high-value work
this fire; top blocked items are X, Y — need hardware QA / user input") and **stop**.

### Hard "do not" list
- **Do not change the attribution label or any persistence key.** The owner-label string is the key
  for Hidden/Shown intent (`ItemControlStore`) and aliases (`ItemAliasStore`); changing how a key is
  formed silently evaporates every user's saved config. This is the scariest landmine here.
- **Do not re-add removed features** (search, section dividers, reveal-on-hover) — see **Removed**.
  NOTE: the old plan file `~/.claude/plans/polished-nibbling-pizza.md` still *describes* search and
  the read-only picker — it is stale; CLAUDE.md is the source of truth, not the plan.
- **Do not weaken, skip, or delete a test to get green.** A failing test is a finding, not an
  obstacle. Fix the root cause or report it.
- **Do not invent features or add knobs.** The user prefers *removing* options. New features need
  sign-off; the loop's default lane is bug-fixing, verifiable hardening, and honest docs.
- **Do not break locked decisions:** macOS 26 only; MIT clean-room (study Ice/Bartender for
  mechanism/UX only, copy no code); the cosmetic baseline must survive any OS change.

### Definition of done for a fire
Build + the full test suite green; security scan (`scan_diff`) clean on the diff; one focused commit
with a surgical diff (every changed line traces to the task); CLAUDE.md updated **honestly** — mark
something RESOLVED only when it is actually verified (distinguish "pure + tested" from "compiles, but
needs hardware verification"; never call a compile a verification). Git rules: never `git push` /
force-push / rewrite pushed history; commits use the GitHub noreply email.

### Circuit breakers — stop and report instead of pushing through
- Backlog has no item that clears the pre-flight gate → report and idle.
- The only work left is high-blast-radius **and** unverifiable here → surface it for a
  hardware/human session; don't attempt it blind.
- You've churned the same area several fires running with no user feedback → stop and ask.
- A change would require disabling a safety check, a test, or a guard to land → stop and ask.

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
- Test: same command with `test` (currently **201 tests, 22 suites**).
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
  `HiddenLayoutPlanner` decides moves; tested against `FakeWindowServer` (162 tests).
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

- **[RESOLVED 2026-06-28] Click-activation was dead on a display left-of/above the primary.**
  `MenuBarItemSnapshot.isClickableOnScreen` tested `frame.minX >= 0` (absolute). A display with a
  negative global x-origin (positioned left of, or above, the primary) has all its on-screen items
  at `minX < 0`, so every activation was rejected and the "click a mirrored item to open its menu"
  feature was 100% dead there — and confusingly so, since the bar still *showed* the items. Fixed:
  `isClickableOnScreen(displayMinX:)` tests against the item's own display origin (default 0 = primary
  / single-display, unchanged); both App call sites resolve the origin from the item's midpoint.
  Pure + tests (incl. the negative-origin case). Same display-relative class as the y/x fixes above.
- **[RESOLVED 2026-06-28] A corrupt/hostile hotkey keyCode crashed the app on every launch.**
  `HotkeyService.register` does a *trapping* `UInt32(combo.keyCode)`, but `HotkeyCombo.isValid` only
  bounded `keyCode >= 0` — a persisted or imported keyCode > 0xFFFF would trap at startup (the
  registration runs in `start()`). Fixed: `isValid` now also requires `keyCode <= 0xFFFF`, so an
  out-of-range code is treated as "unset" and skipped (matching the hotkey layer's never-fatal
  contract). Pure + tests.
- **[RESOLVED 2026-06-28] An imported layout with `version: 0`/negative was accepted silently.**
  `LayoutConfig.decode` checked `version <= currentVersion` but had no lower bound, so a hand-edited
  or corrupt file with a nonsensical version imported as if valid. Fixed: also require `version >= 1`
  (a real export always stamps ≥ 1). Pure + tests.
- **[RESOLVED 2026-06-28] Cross-display attribution dropped `position.y`.** `AXAttributionProvider`
  read each AX extra's full `kAXPosition` but kept only `.x`, and `MenuBarExtraMatcher` matched on x
  alone within a 12pt tolerance. On a multi-display rig every display has its own menu bar at
  near-identical global x (confirmed live: Control Center items at both x≈1106 and x≈3069), so an
  extra on display B could be the global nearest-x to an item on display A and win the assignment.
  Worst part: because `reconcile` attributes *before* moving and the matched extra's **pid** drives
  the synthesized-move scromble relay, a wrong cross-display match could route a *physical* menu-bar
  move to the wrong process — not just a cosmetic mislabel. Fixed in the pure, tested
  `MenuBarExtraMatcher`: both `assignGreedy` and `nearest` gained optional, default-nil y arrays + a
  `yBandTolerance` (100pt) — a pair is a candidate only if its y also agrees within the band. Both
  `kAXPosition` and the window `frame` are top-left global, so same-item y agrees to a few points
  while different-display y differs by ≥ a display height; 100pt cleanly separates them. Wired into
  BOTH call sites (attribution `assignGreedy`, activation-fallback `nearest`) so the two paths stay
  in agreement per the matcher's shared-invariant contract. Default-nil keeps single-display behavior
  byte-identical (all prior tests unchanged) and crucially **does not touch the attribution label** —
  the label is the persistence key for Hidden/Shown intent + aliases, so the fix only *rejects* a
  wrong-display match, never changes how an accepted label is formed. Pure + 7 new tests (cross-
  display rejection, off-display→nil, sub-pixel-drift still matches, malformed-array fallback).
- **[RESOLVED 2026-06-28] No startup login-item reconciliation.** `AppCoordinator.start` wired the
  engine/hotkeys/capture but never touched `loginItem`, so a registration lost to an OS update or a
  manual removal in System Settings was never restored to match the saved `launchAtLogin = true`.
  Fixed: a pure `LoginItemReconciler.decide(desired:actual:)` (Core) maps the live SMAppService
  status to register / unregister / none, and `start()` calls it via a new `reconcileLoginItem()`.
  `requiresApproval` is deliberately left alone (the user disabled it on purpose — re-registering
  every launch would fight that). The decision is pure + 6 tests; `LoginItemService` gained a
  `status` mapped to the Core `LoginItemStatus`. *Decision logic unit-tested; the SMAppService call
  + the start() wiring are review-only (App-target, not hardware-verified this fire).*
- **[RESOLVED 2026-06-28] `launchAtLogin` setter (and import) ignored SMAppService failure.** The
  setter discarded `setEnabled`'s `Bool` and persisted the requested value unconditionally, so the
  toggle could show "on" while registration actually failed (e.g. approval pending). Fixed: the
  setter now persists what *actually* took — `succeeded ? newValue : prior` — so on failure the
  `@Observable` toggle snaps back to the truth (no new View code needed). `importLayout` applies the
  same truth-over-intent rule: if the imported flag's registration is rejected, it records
  `loginItem.isEnabled` instead. *Pure decision shared with the above; the SMAppService outcome is
  review-only.*
- **[LOW, open] Superseded activation's AX sweep isn't cancelled** (`AXActivator` detached task has
  no `Task.isCancelled` checks). A superseded sweep runs to completion (~1.5s) wasting work; it can't
  fire a stale click (the caller's task is cancelled) but it's wasteful. Confirmed by audit-2.
- **[LOW, open] `click()` can warp the cursor to the item and not restore it** if the pre-warp
  `CGEvent(source:nil)?.location` read returns nil (`SystemWindowServer.swift` ~L257/290). Rare;
  leaves the pointer parked in the menu bar. Fix: skip the warp entirely when the save read failed.
  Confirmed by audit-2.
- **[LOW, open] Attribution AX IPC is serial with per-app timeouts** (`AXAttributionProvider` ~L52)
  — N unresponsive apps cost N×timeout on the attribution path. Parallelize with a TaskGroup.
  Confirmed by audit-2.
- **[RESOLVED 2026-06-28] Import had no file-size cap.** `LayoutTransferService.importLayout` did
  `Data(contentsOf:)` then a full `JSONDecoder` on a user-chosen file with no bound, so a huge (or
  hostile) file was read whole into memory. Fixed with one Core constant (`LayoutConfig.maxEncodedSize`
  = 5 MB, ~1000× any real export) used in two layers: the importer checks the file size via
  `resourceValues(.fileSizeKey)` **before** reading (the real fix — never reads a multi-GB file), and
  `LayoutConfig.decode` re-checks `data.count` as a backstop for any other caller, throwing a new
  `LayoutConfigError.tooLarge(Int)`. Additive — never touches the accepted-file shape or any
  persistence key. Pure + 2 tests (oversize→`.tooLarge` before parsing; exact-cap + real export still
  decode). *Decode guard unit-tested; the App-side pre-read size check is review-only.*
- **[LOW, open] `controlItemPositions`/sets serialize via array encoding** with `.sortedKeys` not
  guaranteeing set element order — export diffs can be noisy across runs. Cosmetic. Confirmed by audit-2.
- **[RESOLVED 2026-06-28] Hide silently, partially failed on a wide (5K/6K/ultrawide) display.**
  `ControlItemLength.expanded` clamped the divider width to `[500, 4000]`. The hide mechanism works
  by making the divider WIDER than the display so left-neighbors are pushed off-screen — but on any
  display wider than ~3800pt the 4000 cap made the divider NARROWER than the screen, so the leftmost
  hidden items were never pushed off and hiding silently, partially failed (the worst failure mode
  for a hide tool, and on the *permission-free baseline*). A test even codified the bug
  (`#expect(ultrawide == 4000)`). Fixed: ceiling raised to 9000 — the operating value stays
  `screenWidth + 200` for every real display, the ceiling is now just a backstop above the widest
  real panel (≈7680pt) and still clear of the ~10000 memory-blowup regime. Pure + tests now assert
  the real invariant (`expanded(w) > w` for 1512…6016). Found by an adversarial audit workflow.
  *Caveat:* the 9000 ceiling is the largest value comfortably under 10000; if on-device probing on
  Tahoe ever shows window-server memory growth before then, lower it (but keep it > widest display).
- **[RESOLVED 2026-06-28] `anchorDisplayMenuBarTop` assumed `NSScreen.screens.first` is the primary.**
  The AppKit→CG y-flip needs the *primary* (zero-origin) display's height, but used
  `NSScreen.screens.first?.frame.maxY` — and the array isn't guaranteed to lead with the primary.
  When it didn't, the menu-bar-top offset was wrong and the plausibility filter mis-scoped items on a
  stacked display. Fixed by extracting the conversion into a pure, tested Core helper
  (`DisplayGeometry`: `primaryHeight` finds the zero-origin frame; `menuBarTopY` no-ops to 0 if none
  is present); the engine passes the live `NSScreen` frames in. 8 new tests cover the
  non-primary-first arrangement and stacked-above/below displays.
- **[RESOLVED 2026-06-28] Overtaken capture sequence's tail fought its successor.** After an ~8s
  wedged ScreenCaptureKit call, `awaitBounded` lets a successor start while the orphaned predecessor
  is still live; when the predecessor finally returned, its tail still drove the shared
  divider/state-machine, collapsing the section out from under the successor (flicker / wallpaper
  crop). Fixed: each sequence is stamped with a synchronously-incremented `latestCaptureEpoch`, and
  the tail no-ops unless it's still the latest (`epoch == latestCaptureEpoch`). (`Task` is a value
  type, so identity comparison is impossible — the epoch is the substitute; it's bumped at the exact
  point `captureChain` is reassigned, so it's an equivalent, compiling check.) This also closes the
  `awaitBounded`-non-cancellation finding (the evicted predecessor now backs off harmlessly and
  unblocks the successor faster). Adversarially reviewed; async path, so not unit-tested. NOTE (pre-
  existing, not changed): `reconcileHiddenItems` guards only on `!(floatingBar.isVisible)`, not the
  broader `sectionInUse`, so a user item-toggle can still collapse a section an activation revealed
  for an open menu — by design (reconcile owns its reveal→move→collapse), but worth revisiting.
- **[LOW, open] `colorAlpha` bbox test skips the first/last crop columns** (`IconCaptureService`
  ~L225): a thin colored badge touching the crop edge can lose its outer column, and `p-4` at `x==0`
  is a latent out-of-bounds-row neighbor read. Impact bounded by the 2pt pad. Cleanup; hard to
  unit-test (needs pixel fixtures). Confirmed by the audit.
- **[RESOLVED 2026-06-28] Items on a display stacked above/below the primary were dropped.** The
  plausibility filter (`isPlausibleMenuBarItem`) used an ABSOLUTE `minY ≤ 40` to reject windows far
  down the screen — correct for a transient notification window, but it conflated "near the top of
  its display" with "near global y=0". On a display positioned above/below the primary the menu bar
  lives at a large (or negative) global y, so every legitimate item failed the test: the floating
  bar showed nothing AND the planner refused every move there. Fixed: the filter now takes a
  `displayMenuBarTop` and tests the item's OFFSET from its display's menu-bar top (default 0 →
  unchanged single-display / primary behavior, and the transient-window rejection still holds).
  `CosmeticHideEngine.anchorDisplayMenuBarTop` derives it in CG-global space and threads it to both
  the move planner and the floating-bar enumeration. Pure + 4 new tests. (Natural completion of the
  display-scoping move fix in `4b3201a`; together they handle side-by-side AND stacked displays.)
- **[RESOLVED 2026-06-28] BKF's own anchor icon vanished from the menu bar.** The per-item moves
  churn the two control items' saved `NSStatusItem Preferred Position` slots, and they drifted
  *inverted* (anchor=379, divider=363 — higher slot = further left, so the divider ended up to the
  RIGHT of the anchor). The launch hide expands the divider to push everything to *its left*
  off-screen; with the order flipped that pushed the anchor itself off the left edge (live window
  list showed BKF's status windows parked at negative x while every third-party icon stayed put).
  Fixed: `ControlItemOrder.repairedDividerPosition` (pure, tested) + `repairControlItemOrderIfNeeded()`
  in `CosmeticHideEngine.install()`, run *before* the items are created (AppKit reads the slot at
  creation), rewrites the divider to just-left-of-anchor when inverted. Self-heals on every launch.
- **[RESOLVED 2026-06-28] Synthesized move was flaky on a multi-display setup.** Each display has
  its own menu bar, so `menuBarItems()` enumerates the status windows of ALL displays — the same
  logical item appears as a mirror copy at each display's coordinates (confirmed live: Control
  Center items at both x≈1106 and x≈3069). Only the copy on the anchor's display is movable; a move
  targeting an off-display mirror failed and burned the retry budget. Plus, when the menu-bar
  display changed (anchor jumped 1106 → 3021), the saved intent was never re-applied on the new
  display. Fixed: `HiddenLayoutPlanner.moves` takes an optional `displayXRange` and skips items
  whose midpoint is off the anchor's display; `CosmeticHideEngine.anchorDisplayXRange` supplies it
  from the anchor's current screen; and `screenParametersChanged` now re-reconciles (not just
  re-captures) when there's saved Hidden intent, so a display change re-applies it on the active
  display. Pure + tested (2 new planner tests). `killall ControlCenter` is still the manual unstick
  if the window server itself goes sluggish.
- **[HARDENED 2026-06-28] Screen-parameter changes now debounced.** `didChangeScreenParametersNotification`
  is posted in bursts by macOS (display sleep/wake, mode negotiation, Stage Manager, an external
  display handshaking), and the handler drove a full reveal→capture→hide on each — a burst would
  storm full-display screenshots and visibly flicker the menu bar. `CosmeticHideEngine` now coalesces
  a burst into ONE settled refresh (0.5s debounce, `screenChangeWorkItem`), cancelled on `uninstall`.
  Also added a `DebugLog` line in the handler (there was none, which made the capture cadence
  un-diagnosable from the log). NOTE: verified this is *hardening*, not a fix for a live drain — a
  40s probe saw **zero** screen-param notifications, and the regular ~13s captures seen in the log
  were a finite past episode (user interaction / SIGUSR1), not a runtime timer. There is no periodic
  capture loop in the app.
- **[LOW] Cursor moves during a multi-item reconcile.** With the move now succeeding on attempt 1,
  a single toggle is near-instant, but a large multi-item reconcile (or one with stubborn items
  that retry) still warps the cursor per move via the `defer` in `SystemWindowServer.move`. A
  batch-scoped cursor guard (disassociate + hide + ONE warp-back around the whole reconcile,
  keeping `.cgSessionEventTap`; `postToPid` ruled out as unsafe) would smooth it. Lower priority
  now that moves don't burn 5 failed retries each. Design is in memory `bkf-private-api-direction`.
- **[RESOLVED 2026-06-28] Reconcile attempted (and failed on) transient status-layer windows.**
  Some apps park non-glyph windows at the status layer (Karabiner's notification window, low on
  screen; tall popovers). They share their app's owner key, so a "hide that app" intent reached
  them and the move burned the full retry budget failing on each. Fixed: the planner now skips any
  item failing `HiddenItemsResolver.isPlausibleMenuBarItem` (height/width/top-edge bounds) — the
  same filter the floating-bar resolver uses. Verified on-device: 4 NotificationWindow attempts → 0.
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

- **Settings window refinement (UX polish).** *(User feedback 2026-06-28: "looks like someone new
  built it… refine it and make it a proper app." Low priority, loop item.)* It's currently a bare
  two-tab `Form` (`SettingsView.swift`, 460×580) with no app identity, no header, default control
  density. Make it feel shipped: an app header (icon + name + version), a sidebar/`NavigationSplit`
  layout instead of a cramped tab strip, consistent section spacing and footnotes, an About area.
  Pure-logic content is fine as-is; this is presentation. Bartender/Ice are good visual references
  for what "refined" looks like here (UX observation only — clean-room, no code).
- **Rich anchor right-click menu.** *(User feedback 2026-06-28. Low priority, loop item.)* The
  anchor's context menu is currently only **Settings… / Quit** (`CosmeticHideEngine.showAnchorMenu`,
  ~L433). The user wants a proper app menu: **App name + version** (header), a **status line**,
  **Pause** (suspend hide/reveal + the move so the bar behaves like a vanilla menu bar), **About**,
  **Check for Updates** (needs Sparkle — see below), **Restart**, plus the existing Settings/Quit.
  Design notes:
  - *Status* should reflect real engine state, mapping to the user's vocabulary: **Ready** (idle),
    **Working** (a reconcile/synthesized move in flight), **Collecting** (a capture sequence
    running — `captureInFlightCount > 0`), **Update available** (Sparkle found one). Model it as a
    pure `AppStatus` enum in Core (driven by counters the engine already tracks) so the label is
    unit-tested, not ad-hoc string-building in the menu builder.
  - *Pause* is the meatiest piece: it must reveal+leave-revealed (or no-op the divider) AND stop
    reconcile/auto-rehide/hotkey toggles until un-paused, persisted across launch. A clean `paused`
    gate in the engine, surfaced as a checkable `NSMenuItem`.
  - *Check for Updates* and *About*'s version string both presuppose **Sparkle** is wired (it isn't
    yet — see last bullet); until then show the bundle version and gray out / hide Check for Updates.
- **Per-item / global hotkeys** to toggle a *specific* item. (Deferred until the synthesized move
  is hardware-verified — don't keep building on an unproven mechanism.)
- **Triggers / automation** — battery / wifi / app-active / schedule → apply a preset.
- **Presets / profiles** — saved arrangements, per-display or per-Space.
- **Layout Mode: On-Demand vs Live** *(idea from Bartender's onboarding, 2026-06-28 — the clean
  reframe of our cursor-warp problem).* Bartender makes the user choose up front: **On-Demand**
  ("you're in control" — only moves items when you ask, never interrupts the mouse) vs **Live**
  ("always organized" — auto-sorts on every add/remove, "may cause a temporary mouse interruption").
  They don't *hide* the cursor jump; they make non-interruption the default and let power users opt
  into auto-organize. BKF is already On-Demand-shaped ("only moves what the user explicitly
  toggled"), so this validates our direction — adopt the *name* now (frame the current behavior as
  On-Demand) and treat Live (auto-reconcile on menu-bar change) as the future opt-in. This also
  gives the batch-cursor-guard work a home: it's the thing that makes a future Live mode tolerable.
- **Always-Hidden tier** — a second section never shown in the bar (deferred; Tahoe broke nested
  sectioning for Ice, so approach with care).
- **Menu-bar item spacing** (global `NSStatusItemSpacing`) — opt-in, force-relaunches every
  menu-bar app; ship only with a clear warning + reset.
- **First-run onboarding** — a guided welcome flow (the Permissions *panel* in Settings is done;
  what's left is a proactive first-launch walkthrough rather than the user finding Settings).
  *Bartender's onboarding (2026-06-28 screenshots) is a good model:* a feature-overview grid, then
  the Layout Mode choice (above), then a dedicated full-screen **Grant Permissions** step with crisp
  per-permission benefit bullets ("Screen Recording → see items in the bar / live previews / capture
  for search"; "Accessibility → move & rearrange / click to show menus / hide & show automatically").
  We already have the live status + deep-links in Settings; onboarding is just surfacing them
  proactively on first launch with that benefit copy.
- **Sparkle auto-update**, **notarized DMG** distribution.

## Hard constraints / gotchas

- **macOS 26 only.** `kCGWindowOwnerPID` is broken (FB18327911 — everything reports as Control
  Center), so owner attribution is by frame-matching AX extras, not PID.
- The synthesized move and capture are the fragile bits — keep them behind `WindowServer` /
  `IconCaptureService` with graceful fallback, never let them crash the permission-free baseline.
- Don't `pkill` an Xcode-launched instance (state `SX`); ask the user to press Stop.
- Keep this file current: when you finish a feature move it to **Built**, when you find a bug add
  it under **Bugs**, when you remove something note it under **Removed**.
