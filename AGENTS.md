# AGENTS.md - Bar Keeper's Friend

Instructions for coding agents working on this repo. This file is the running source of
truth for **what's built, what's left, and what's broken**. Keep it current.

## What this is

A native macOS **Tahoe (26) only** menu bar manager (like Bartender / Ice): hide, organize,
and reveal status bar icons. MIT, clean-room (Ice studied for mechanism only, no code copied).
Public repo `aagrawal207/bar-keepers-friend`; commits use the GitHub noreply email, never the
Amazon address.

User's bar: **flawless, very well tested**, effort no object. Default to removing confusing
options over adding power-user knobs.

## Current direction

The user has authorized commits and pushes and requested continued work toward Bartender parity.
Track actual capabilities and verification gaps in [PARITY.md](PARITY.md); do not equate a passing
build with complete parity. Choose the best engineering approach without asking for routine
recommendations. Native behavior still requires evidence, and the safety gates below still apply.

The user explicitly requested hover reveal again on 2026-09-11: an opt-in setting below Auto
Re-hide that opens the floating bar when hovering over the BKF icon and closes a hover-owned bar after leaving.
Click/keyboard ownership, Pause, and disabling the setting must remain authoritative.

The user requested staged placement and Settings previews on 2026-09-12. Hidden/Shown edits now
stay in a session-only draft until Apply Changes; Discard abandons only the draft. Preview rendering
must remain cache-only. Apply uses the existing serialized mover, not parallel native gestures.

## Loop charter (read first if you are an automated loop fire)

A recurring task fires here every ~30 min ("build the next feature or fix a critical bug, keep
AGENTS.md current"). The app is now in good shape; the easy, safe, high-value backlog is draining.
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
- **Do not re-add removed features** (search or visible section dividers) without an explicit
  request. Hover reveal has fresh user approval; see Current direction. Historical plans are not
  current requirements; AGENTS.md is the source of truth.
- **Do not weaken, skip, or delete a test to get green.** A failing test is a finding, not an
  obstacle. Fix the root cause or report it.
- **Do not invent NEW features or add knobs.** The user prefers *removing* options. But as of
  2026-06-29 the loop IS cleared to pick up **already-documented** low-priority items from "Features
  not yet built" below (they have implicit sign-off) — building them incrementally, one focused
  commit at a time, each still clearing the pre-flight gate. The line that still holds: don't dream
  up features that aren't written down here, and put the load-bearing logic in Core with tests even
  when the surrounding UI can only be review-verified. Anything genuinely new still needs sign-off.
- **Do not break locked decisions:** macOS 26 only; MIT clean-room (study Ice/Bartender for
  mechanism/UX only, copy no code); the cosmetic baseline must survive any OS change.

### Definition of done for a fire
Build + the full test suite green; security scan (`scan_diff`) clean on the diff; one focused commit
with a surgical diff (every changed line traces to the task); AGENTS.md updated **honestly** — mark
something RESOLVED only when it is actually verified (distinguish "pure + tested" from "compiles, but
needs hardware verification"; never call a compile a verification). Push only with user authorization;
never force-push or rewrite pushed history. Commits use the GitHub noreply email.

### Circuit breakers — stop and report instead of pushing through
- Backlog has no item that clears the pre-flight gate → report and idle.
- The only work left is high-blast-radius **and** unverifiable here → surface it for a
  hardware/human session; don't attempt it blind.
- You've churned the same area several fires running with no user feedback → stop and ask.
- A change would require disabling a safety check, a test, or a guard to land → stop and ask.

## Architecture (the seam is the point)

Core logic is tested separately from AppKit. Native move/click operations use `WindowServer`;
the floating-bar controller accepts injectable capture, attribution, and AX activation closures.

- **`BarKeepersFriendCore`** (static lib) — pure value types + logic. No AppKit. Swift Testing.
  Hide/show state machine, layout math, notch geometry, planners, persistence, attribution
  matcher. This is where most logic lives and where new logic should go.
- **App target** (`LSUIElement` agent app) — AppKit/SwiftUI shell that wires Core to the OS:
  status items, the floating bar panel, capture, the synthesized move, settings.
- **`WindowServer` protocol** is the single seam to the fragile/private window-server surface;
  `FakeWindowServer` backs the tests, `SystemWindowServer` is the real impl.
- **`BarKeepersFriendAppTests`** compiles the real App adapters without the app entry points.
  It tests capture/move orchestration with fakes and measures SwiftUI content off-screen through
  `NSHostingController`. It never installs status items, captures the desktop, or posts mouse events.

## Build / test / run

- Generate project after adding/removing files: `xcodegen generate` (the `.xcodeproj` is
  gitignored — `project.yml` is the source of truth).
- Build: `xcodebuild -project BarKeepersFriend.xcodeproj -scheme BarKeepersFriend -destination 'platform=macOS' build`
- Test: same command with `test` (currently **510 tests, 42 suites**, 833 invocations including
  parameterized cases). Last full build/test: 2026-09-12, macOS 26.6.2 / Xcode 26.6, zero failures
  or skipped tests. The built app also passed `codesign --verify --deep --strict`.
- Adapter tests only: append `-only-testing:BarKeepersFriendAppTests` to the test command. Their
  `BKF_TESTING` compilation condition keeps synthetic diagnostics console-only; production logging
  is unchanged. AppKit hide-animation completion still produces pre-existing actor-isolation
  compiler warnings on a full compile.
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
  APIs — the unbreakable baseline. Divider width bounded `[500, 9000]` (never literal 10000).
- **Floating bar** — mirrors hidden (left-of-anchor) items in a panel below the menu bar
  (horizontal strip / vertical list). Captures each icon's image while on-screen (off-screen
  items can't be captured), caches it, shows from cache. Monotonic cache + two-pass warm-up so
  first load is clean. Slide+fade animation, Reduce-Motion aware. Needs Screen Recording.
- **Activate a mirrored item** — reveal section → synthesized CGEvent click → leave revealed so
  the menu opens. Needs Accessibility. Background cursor concealment is implemented and its native
  hide/show capability is verified; universal absence of event-time flicker remains unverified.
- **Per-item Shown/Hidden (private API) — VERIFIED WORKING on-device 2026-06-28.** Settings → Items
  lists every manageable item with a Shown/Hidden segmented control; Apply Changes **physically
  moves** the requested items across the anchor. The move uses Ice's two-tap "scromble" relay (a direct
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
- **Shown/Hidden consistency, re-verified 2026-09-11.** Native drops carry the destination
  control's window ID, not the dragged window's ID. The mover resolves fresh control/item frames
  for each attempt and verifies the entire item reached the requested side. Hidden is measured
  against the actual divider, including its natural width. When Tahoe supplies no usable AppKit
  window number, controls are resolved by their unique, exact native window names on the display.
  Settings shows observed placement, progress, and failures; repeating an unmet request retries
  without rewriting identical preferences. A single or bulk Shown request no longer depends on
  changing the Hidden set, and opening Settings dismisses the mirror.
- **Global toggle hotkey** — ⌥⌘B via Carbon `RegisterEventHotKey` (no Accessibility prompt).
  Keyboard-opened bar persists until re-toggled (doesn't auto-dismiss).
- **Opt-in hover reveal (2026-09-11, pure + adapter-tested).** Settings > General > Behavior has
  "Reveal on hover" below Auto Re-hide. It defaults off, is independent of auto-rehide, and is
  unavailable outside floating-bar mode. A 200ms dwell opens the cached bar; leaving the anchor,
  panel, and connecting gap closes only a hover-owned panel after 400ms. Pointer polling runs at
  20Hz only while enabled, and stops on Pause, disable, or uninstall; it is not a capture timer.
  Manual interaction cancels pending hover work, and native placement cannot clear manual-close
  suppression with a temporary cursor excursion. Held mouse buttons block new hover opens without
  closing an item being clicked. Right-click closes a hover-owned panel before opening its menu.
  Hover presentations use non-key window ordering, retained through re-layout; click/keyboard
  opens keep their existing policies. Pure geometry/state tests, fake-clock cancellation tests,
  real engine/placement wiring, and intercepted NSPanel ordering calls verify these decisions.
  Native first-click delivery, focus, animation transit, and display behavior still need hardware QA.
- **Cache-only list opening (2026-09-11, adapter + limited native verification).** Hover, click,
  and keyboard opens no longer request a reveal/capture pass. Optional refreshes and warm-up retries
  recheck eligibility after joining predecessors; skipped successors still restore the divider.
  Warm-up re-arming cannot invalidate an unrelated display refresh. Hover waits for capture and
  divider restoration; a manual open during an already-active capture retains its previous behavior.
  Native diagnostic opening showed the panel with the divider at 1728pt in all 40 samples. Stale or
  unfinished icons wait for existing lifecycle/display/placement refreshes; there is no general idle
  refresh scheduler or freshness guarantee on reopen.
- **Background cursor concealment (2026-09-11, adapter + native capability-tested).** Dynamic
  `CGSSetConnectionProperty` enables `SetsCursorInBackground` only on BKF's own connection. The
  unlocked, inactive-process probe changed cursor visibility from 1 to 0 to 1; without it, hiding
  was ineffective. Position restoration and one balancing show are scoped across errors/cancellation.
  Missing restore points prevent gestures. Locked/non-console sessions stop new pointer and AX work;
  delayed relay callbacks and fallback cannot revive an interrupted down, while a submitted down
  still receives a balancing up. Interrupted current activations release their reveal without
  disabling the item; superseded activations leave successors alone. Interrupted placement remains
  pending. A native click using the production bridge opened Itsycal on the built-in display and
  returned the cursor within one point, stable after 350ms. This conceals existing movement, not a
  universal pointer-free transport; visual flicker across apps/displays still needs hardware QA.
- **Anchor right-click menu** — app name + version header, a live **status line** (Paused / Ready /
  Working… / Collecting icons…, from the pure `AppStatus` enum in Core), a checkable **Pause** (reveals
  items in place and stops all automated hide/reveal/move; session-only), **About** (standard panel),
  Settings, Quit. *(Restart / Check-for-Updates still to come — see "Rich anchor right-click menu".)*
- **Auto re-hide**, **dismiss-on-mouse-exit** (gated on the pointer having first entered the
  panel, so a revealed bar doesn't vanish instantly), **launch at login**, **layout
  export/import** (versioned JSON), **per-item display aliases** (nicknames in the bar/Items
  list), **multi-display** anchor placement, **notch-safe** geometry.
- **Permissions panel** — Settings → General shows live Accessibility + Screen Recording status
  (Granted / Needs re-approval / Not granted), explains what each unlocks, and offers an "Open
  Settings…" button per permission. Polls while open so a freshly-granted permission updates
  without reopening. Both are optional (the cosmetic baseline needs neither), so it never blocks.
  Pure `PermissionState` machine in Core + `SystemPermissionProbe` in the app target.
- **Floating bar grid wrapping** - `FloatingBarView` uses the same cell metrics and padding as
  `FloatingBarLayout`; incomplete horizontal rows align left. The panel is sized from the hosted
  content, including the empty/preparing states. Off-screen hosting tests verify both styles at
  wrapping boundaries and 80 items on a 1512x982 display, with default/custom metrics and long
  aliases. This verifies actual SwiftUI sizing, not just Core rectangles. Displayed appearance,
  hit targets, and layouts exceeding the capacity of both axes still need hardware QA.
- **Floating-bar item feedback (2026-09-11, rendering-tested).** List rows and icon cells share a
  rounded hover highlight with stronger pressed feedback. Idle/disabled items draw no highlight;
  button actions, hit rectangles, and cell metrics are unchanged. Off-screen AppKit bitmap tests
  verify light/dark pixels, full-cell coverage, disabled-state transparency, and unchanged sizing.
  Native pointer enter/exit in click-opened and hover-opened panels still needs hardware QA.
- **Items list grouped Hidden / Shown** — Settings → Items splits into "Hidden (N)" and
  "Shown (N)" sections instead of one interleaved list, so the two states scan at a glance and a
  toggled row visibly moves between them without a menu-bar re-scan. `SettingsModel.partition`
  uses draft choices while editing, requested placement while applying, and observed placement
  afterward. Failed moves do not masquerade as completed placement.
- **Staged placement and Settings previews (2026-09-12, pure + adapter + rendering-tested).**
  Hidden/Shown and Hide All/Show All edit an owner-keyed `ItemPlacementDraft` without persistence,
  enumeration, capture, or native movement. Apply merges only edited placements into current
  preferences once; identical saved intent requests a fresh reconciliation, never trusting cached
  flags as proof of native success. Discard leaves saved intent alone. Reversals preserve absent
  intent, and choosing the observed side can replace an opposing saved request while paused.
  Partial failures remain observed and retryable; repeated Apply cannot replace an active batch.
  Drafts survive Settings close/reopen within the session, but not app restart. Successful import
  replaces the draft; failed/cancelled import does not. Aliases save separately and survive row
  regrouping without overwriting a newer rename.
  Settings has inert Menu Bar and Hidden Bar/List schematics using cached glyphs/app icons.
  "After Apply" projects merged saved-plus-draft intent; "Last Observed" uses loaded observations,
  with unknown placement separate. These are manageable-item previews, not exact screen replicas.
  The 640x720 window keeps its footer visible and cached rows present during reloads. Off-screen
  tests cover actual controls, light/dark pixels, overflow, aliases, unknown placement, and full-window
  fit with read/placement errors. Test windows never order on screen. Pointer/VoiceOver feel and
  external-display placement still need native QA. No native delays, relay, or capture transport changed.
- **Hide All / Show All** stage all applicable owner choices in the same draft, including explicit
  choices for unknown placement. Buttons disable only when staging would be a no-op. One Apply
  submits the whole mixed-direction batch through the existing serialized reconciliation.
- **App icon** — a custom mark in `Sources/App/Assets.xcassets/AppIcon.appiconset` (a white
  menu-bar pill with three item dots, a left "tuck" chevron = BKF's hide control, and a cleaning
  sparkle, on a teal→blue squircle — the Bar Keepers Friend pun). Rendered by `Scripts/render_icon.swift`
  (pure Core Graphics, no SVG toolchain needed) at the 10 standard macOS renditions; wired via
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. Verified in the built bundle (`AppIcon.icns` +
  `Assets.car`, `CFBundleIconName=AppIcon`, `assetutil` lists all renditions). Matters even for an
  agent app: the Settings header and the About panel both render `NSApp.applicationIconImage`
  (previously the blank generic icon). *Large/mid sizes verified by eye here; the in-Settings/About
  appearance is review-only (no Settings visibility from this rig).*

## Removed (intentionally — don't re-add without asking)

- **Search panel** + its ⌥⌘F hotkey — user found it confusing.
- **"Show section dividers"** toggle — divider is now an invisible mechanism only.
- **Previous reveal-on-hover implementation** - removed because the user did not want it and its
  off switch did not fully stop it. The replacement explicitly requested on 2026-09-11 is opt-in
  and cancellation/ownership-tested; see Built for its verification scope.

## Remaining work

### Bugs (open)

- **[MITIGATED 2026-09-12, adapter-tested] Every Settings selection repeated expensive placement work.**
  Editing is now local; multiple choices share one Apply sequence. A mixed-direction integration
  test verifies one preference write, one placement attribution pass, sequential moves, and one
  successful post-batch capture, rather than a cycle per edit. Native settling/retry delays and
  separate capture/Settings attribution sweeps remain; this is not a measured native latency fix.
  The unresolved external-display failures can still exhaust retries during Apply.
- **[RESOLVED 2026-09-12, rendering-tested] Row regrouping lost an unfinished alias edit.**
  Mounted field-editor tests reproduced alias loss when Hide All, Discard, or placement completion
  moved a row between section subtrees. Disappearance commits use the same guarded path as Return
  and blur; an intervening saved rename wins over the stale edit. Tests cover all three regroup paths.
- **[FIXED 2026-09-11, adapter + limited native verification] Opening the list revealed real items.**
  Stale-cache checks queued capture before the panel became visible; already-queued optional work
  also lacked execution-time visibility checks. Opens are cache-only, and optional work yields to
  current presentation. Tests invoke the actual engine/show paths and record physical divider writes.
  Existing active capture and explicit item activation are separate from this fixed opening path.
- **[IMPLEMENTED 2026-09-11, rendering-tested; native hover QA pending] Items had no pointer feedback.**
  Both `FloatingBarView` item renderers used plain buttons with no hover state or background.
  A shared button style now owns hover state per item and draws only for enabled hovered/pressed
  items. Tests use `NSHostingController` drawing: `ImageRenderer` produced a disabled-state artifact
  even with the background absent, so it was not a trustworthy transparency oracle for this view.
- **[OPEN 2026-09-11] External-display startup collected no real glyphs.** After the standalone
  restart at 19:53 UTC on the 1920-point display, 3840x2160 captures repeatedly yielded 0/9
  on-screen glyphs; the cache held nine app-icon fallbacks. Placement completed with zero moves.
  This is a capture/recovery verification gap, not a demonstrated timing diagnosis. The highlight
  change touched no capture code; the cause and recovery on this display remain unverified.
- **[OPEN 2026-09-11] Itsycal Shown failed on the external display.** Two live requests on the
  1920-point display each exhausted five attempts: window 58 stayed at x=1525 while the anchor
  was x=1625, despite both relay legs reporting submission. This was a real failed placement,
  not merely a stale Settings label. After the display changed back to 1512 points, the saved
  Shown intent succeeded on the first attempt (x=1114 to x=1238). External-display recovery has
  not been verified. Do not call this fixed based on the built-in-display success or assume a
  longer delay/width-specific offset is the answer without a demonstrated cause.
  **Investigation:** an unlocked two-display snapshot showed original window 58 at y=-30 and its AX
  extra at y=-27, while a distinct bundle-named compositor window represented Itsycal at y=0. BKF's
  named controls and visible compositor controls also differed. This supports a representation/context
  mismatch hypothesis, not a proved relocation fix. External displays were disconnected before a new
  move could be verified. Built-in Shown placement was already satisfied and is not counted as a fix.
  Both direct AXPress and the production click bridge opened Itsycal's menu on the built-in display.
- **[RESOLVED 2026-09-11, adapter-tested + live placement verified] Shown did not restore items.**
  The user's running build did reach the native mover: ACME and Maccy initially logged move
  failures. A subsequent instrumented run moved ACME but falsely called Maccy successful because
  ACME's relocation shifted Maccy from x=1152 to x=1118 while it was still hidden. The old test
  accepted any displacement from the original batch snapshot. Relative native destinations and
  fresh full-edge postconditions replace that check. The AppKit control-ID lookup also returned
  no usable IDs on this rig, despite the named control windows being present; the native lookup
  closes that gap without changing autosave names or keys. The fixed build moved Maccy from
  x=1122 to x=1330 on its first attempt. An independent WindowServer read after collapse showed
  anchor=[1222,1254], Maccy=[1330,1362], ACME=[1362,1396], both items marked on-screen, with the
  divider expanded to 1728pt. This verifies placement, not the absence of visible cursor motion.
  A subsequent standalone relaunch needed zero moves and kept both items on the shown side.
- **[RESOLVED 2026-09-11, adapter-tested] Settings reported intent as completed placement.**
  Rows now use observed section membership; failed moves remain actionable and show an error.
  Direct picker bindings replace the on-appearance state writeback, so loading a row does not
  write intent or re-register shortcuts. Shown-only changes and identical retries reach the
  serialized placement path. Deferred requests resume on permission recovery, unpause, or genuine
  dismissal, not while an item menu is opening. Superseded activations join any draining move
  before clicking; withdrawing intent restores the divider only after old work relinquishes it.
- **[RESOLVED 2026-09-11, adapter-tested] Read races could erase or mislabel valid cached items.**
  Failed enumeration is not treated as an empty menu bar. Cached owners survive unresolved AX
  reads only for continuously observed window IDs; disappearance invalidates them. Candidate and
  control geometry are checked before committing attribution or images. Settings loads use
  generation ownership, retain previous rows on read errors, and clean up loading on cancellation.
  Rejected first captures remain unfinished work and receive the bounded warm-up second pass.
- **[OPEN, verification scope] Remaining Bartender-level gaps.** Cursor flicker and some native
  menu-activation behavior still need a live user check. Full cold-from-boot capture, multi-display
  representative selection, and recovery from a genuinely non-returning native call are not proved
  by these tests. The frame matcher remains heuristic; this pass did not change its labels,
  tolerance, or greedy assignment policy. No claim of full Bartender feature parity is made.

- **[RESOLVED 2026-09-10, adapter-tested] Pause did not cancel queued/in-flight work.** The old
  request-time guard let a pending reconcile move items after Pause and let its completion hide
  them again. Three hostless regression tests failed against that behavior before the fix.
  Cancellation now reaches the whole capture chain, with checks after suspension and before each
  new move/capture. Late results cannot replace the icon cache or re-hide the section. Native
  move retries stop between complete down/up pairs; the event-routing mechanism is unchanged.
  Disable/uninstall also cancel pending work. Resume restarts unfinished icon collection even
  without Accessibility. Tests cover queued cancellation, attribution/capture suspension, a
  partially completed move batch, fresh work after resume, and late AX success/failure cleanup.
  Real native cancellation timing and cursor restoration remain hardware-only verification.
- **[RESOLVED 2026-09-10, hosting-tested] Floating-bar content exceeded its allocated frame.**
  The view independently used 26pt cells plus 6pt gaps and 200pt vertical columns, while Core
  allocated 30pt cells and 190pt columns. At 80 horizontal items the rendered row was 1578pt on
  a 1512pt display. Shared metrics fix the mismatch; intrinsic sizing also stops the 240pt empty
  message from being squeezed into a one-cell frame. No capture keying or click routing changed.
- **[RESOLVED 2026-09-10, pure + persistence-tested] Imported delays could crash Settings.**
  A finite `autoRehideDelay: 1e20` reached a trapping `Int` conversion and was saved before the
  view rendered. Initialization, decoding, and mutation now clamp finite delays to the existing
  2...120s UI range; nonfinite values use 15s. Valid fractions remain intact. Tests cover legacy
  saved data and import/save/reload while preserving aliases, item intent, and Codable keys.
- **[RESOLVED 2026-09-10, adapter-tested] Cancelled Items-tab loads could overwrite newer data.**
  `SettingsModel.reloadItems` owns the loaded items/loading state and ignores cancelled results.
  Tests finish an older cancelled load both before and after its replacement. Attribution label
  construction and persistence identity are unchanged.
- **[OPEN 2026-09-10] The capture queue's eight-second timeout is not a hard timeout.**
  `awaitBounded` races a task-value waiter against a sleep inside a structured task group. Group
  exit still waits for the waiter, so a non-returning native operation blocks later sequences.
  Cancellation now prevents later side effects but cannot force that native call to return.
  Do not claim timeout recovery is verified, or replace the wait with overlapping operations
  without isolating native move/capture ownership. The older "overtaken capture" note is corrected
  below. This is code-traced, not a reproduced live ScreenCaptureKit hang.
- **[LOW, open 2026-09-10] Export errors and login approval need clearer feedback.** Export
  returns `nil` for both cancellation and write failure, clearing the status line in either case.
  Launch-at-login shows saved intent without exposing `.requiresApproval` or the existing System
  Settings recovery action. Both are code-traced Settings gaps; neither is fixed in this pass.

- **[OPEN 2026-06-30] Activation click visibly moves the cursor ("the whole mouse moves"), and some
  items' menus don't open.** User-reported. The activation click (`SystemWindowServer.click`) warps
  the REAL pointer onto the item, posts a positioned click, warps back — because status-item
  hit-testing tracks the physical pointer and the owning app anchors its menu where the cursor is.
  The `CGDisplayHideCursor` meant to mask the warp is a no-op for our `.nonactivatingPanel` (honored
  only while foreground), so the dart-and-return is visible.
  - **ATTEMPT 1 (commit `987c3d6`) — FAILED LIVE, REVERTED (this commit).** Tried routing the click
    by windowID through the `scrombleEvent` relay (like the MOVE), per the `bkf-private-api-direction`
    memo's premise "route by windowID → no cursor warp at all." On-device the user reported it was
    **worse**: the cursor still moved (and now stayed displaced — I posted at the item centre and
    dropped the warp-back), and only SOME menus opened. **Why it can't work as imagined:** posting any
    `CGEvent` with a `mouseCursorPosition` MOVES the system cursor regardless of windowID stamping —
    that's why the MOVE path itself still hides+warps-back the cursor (`move()` L120-128, memo line 20
    "Cursor hidden + warped back, never dragged"). And a windowID-routed *plain* click is less reliable
    at opening a menu than a real positioned click — the server's by-windowID special-casing is for the
    ⌘-drag rearrange, not a menu-open. So the premise was wrong; reverted to the known-good warp click
    (opens menus reliably; cursor flickers but returns). Lesson recorded so no future fire retries it.
  **Cursor proposal corrected (2026-09-11).** Do not add HID disassociation as a purported fix for
  the explicit warp. Apple's [cursor documentation](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html)
  explicitly permits `CGWarpMouseCursorPosition` to reposition the cursor while disassociated.
  Disassociation does not hide it, and the posted-event interaction still needs native evidence.
  Preserve balanced restoration and distinguish event submission from observed menu opening.
  **Implemented concealment:** see Built for the own-connection background-cursor property and
  native probe results. Original pointer movement remains in the click/move path; there is no claim
  that every visible flicker or menu-activation compatibility issue has been eliminated.
  - *Related, still open: (#2) activation reveals the strip on-screen ("menu bar items pop up again")
    — inherent to needing the menu on-screen; revisit only with a confirmed click path. (#3) displaced
    Battery CC-module still in the bar — separate hardware-QA item below.*

- **[RESOLVED 2026-06-30] "Hide All" swept Control Center modules + BKF itself into the hidden set,
  so reconcile thrashed forever and the app became unusable** (user-reported with 3 screenshots:
  floating bar showed only 1 item, Settings showed "Hidden (20)", yet nothing was physically hidden).
  Reproduced from the LIVE standalone instance's reconcile log: `hiddenInMenuBar` contained `"Battery"`,
  `"Sound"`, `"Clock"`, `"Audio and Video Controls"`, the screen-recording privacy string, AND
  `"Bar Keeper's Friend"` — i.e. "Hide All" had marked Control Center's own modules and the app itself
  as hidden. Every reconcile then planned moves for them; CC modules can't be relocated by the window
  server (they snap back) and moving our own anchor shifts the very hide/show boundary, so the pass
  NEVER reached zero moves — the anchor walked across the bar each cycle (logged: 993→1163→1147→3260→
  1356→1489) and the mirrored set was different every refresh (hence "only 1 item"). The fullscreen
  transitions the user noticed just re-triggered the already-broken reconcile; fullscreen was not the
  cause. **Fix:** an `immovablePIDs` set — Control Center's pid (caught via `NSRunningApplication`
  bundle id `com.apple.controlcenter`) + our own `getpid()` — threaded into `HiddenLayoutPlanner.moves`
  and the Settings picker (`allManageableItems`), both of which operate on ATTRIBUTED snapshots where
  each item carries its real owning pid. One Control-Center pid catches EVERY module at once
  (locale-independent — far better than enumerating localized labels like "Wi-Fi"/"Battery", which is
  exactly the residual the old `denylistedOwnerLabels` note said needed on-device confirmation). Pure
  `ImmovableItems.isImmovable(_:immovablePIDs:)` overload (raw-snapshot-unsafe by contract — documented)
  + new App helper `ImmovableProcessIDs`. **VERIFIED ON-DEVICE 2026-06-30:** relaunched the fixed build
  standalone; the reconcile plan dropped Control Center modules (pid 22986) and "Bar Keeper's Friend",
  the anchor settled (stable at 1489 across consecutive passes) and reconcile stopped self-retriggering
  for 17 min (vs every ~40s before) — it converges. Pure Core + 6 tests (CC-module-by-pid, own-app-by-pid,
  unlisted-pid still moves, empty-set == label-only). *RESIDUAL (separate, pre-existing): the user's
  persisted `hiddenInMenuBar` still CONTAINS those bogus keys — the fix makes them inert no-ops (never
  planned, never listed). NOT auto-purged (mutating persisted intent is the persistence-key landmine).*
  - **RE-VERIFIED 2026-06-30 ~14:53 (live PID 27050, 25 min after the fix):** reconcile has not
    self-triggered since 19:45 UTC (anchor stable at 1559; pre-fix it fired every ~40s with the anchor
    walking 993→3260→1356→…), and `BKF-bar.png` renders 6 real items with real glyphs (Karabiner-Menu,
    Battery, Wisp, Amazon Persist, Maccy, Hammerspoon). Attribution also fully RECOVERED — the 14:01
    "all Control Center" reading was the transient AX lapse, now resolved (all 7 items attribute to
    distinct real owners), confirming it was never a code regression.
  - **NEWLY FOUND — "Show All" can't recover a CC module the OLD buggy binary already displaced.**
    The live diag shows **Battery** (pid 22986 = Control Center) sitting at x=1335, LEFT of the anchor
    (1559) — i.e. dragged into the hidden section by the pre-fix thrash, so it now renders in the
    floating bar. Because the planner now (correctly) refuses to move any pid-22986 item, "Show All"
    sets its intent to Shown but CANNOT physically move it back — it stays stuck left until Control
    Center relaunches (`killall ControlCenter`) or a reboot re-lays-out its modules. This is the right
    trade (forbidding CC-module moves is what stopped the thrash; a "recover displaced CC module" move
    would re-enter the exact un-relocatable-move territory we just removed, and is unverifiable from
    this rig anyway — see "Needs hardware verification"). The earlier RESIDUAL line calling "Show All"
    a full clean-slate reset was therefore incomplete for already-displaced CC modules; corrected here.

> **Pure-Core audit clean (2026-06-30).** A full read-through of all 28 `Sources/Core` files this
> fire found **no open Core bug** — every pure value type / planner / store / state machine is
> correct and unit-tested. The only opens below are the two **[LOW, open]** App-target items
> (`AXAttributionProvider` serial AX IPC; `IconCaptureService` `colorAlpha` edge columns), both
> blocked on hardware verification / pixel fixtures. Future loop fires: don't re-audit Core for bugs
> — it's drained. The next real work is App-target/on-device (hardware QA) or a documented feature
> from "Features not yet built", not a Core bug-hunt.
>
> **Scope correction (2026-09-10):** that was a historical Core-only audit, not proof of App wiring
> correctness. The integration review above found reachable defects despite all 234 prior tests
> passing. Continue from concrete reproductions; do not repeat an undirected Core audit.

- **[RESOLVED 2026-06-29] The Settings Items picker could list BKF's own anchor as a hideable row.**
  Two "exclude our own control items" paths had diverged: the floating-bar resolver
  (`HiddenItemsResolver.hiddenItems`) excludes by window id **and** the `isOwnControlItem` name-prefix
  check, but the Settings picker (`FloatingBarController.allManageableItems`) excluded by window id
  **only**. The name-prefix guard exists in Core precisely because the window-id set can be stale on
  Tahoe (ids are reassigned when a status item is recreated; `publishControlItemWindowIDs` refreshes
  it before a *show*, but the picker enumerates independently). With a stale id set, BKF's own anchor
  /divider would pass the picker's filter (and the downstream `key != nil && !isImmovable`, since the
  control items' owner name isn't denylisted) and appear as a manageable, hideable row — letting the
  user hide their own anchor. Fixed by adding `&& !HiddenItemsResolver.isOwnControlItem($0)` to the
  picker's candidate filter, matching the resolver's belt-and-suspenders. Reuses the pure, already-
  tested Core guard; strictly subtractive (only ever excludes our own items); no capture/move/baseline
  path touched. App-target glue, so no new test — `isOwnControlItem` is already unit-tested in Core.
- **[RESOLVED 2026-06-29] A lapsed permission silently downgraded to "Not granted" after ~1s.**
  `PermissionState.refresh` marked a permission `.lapsed` (was-granted-now-not, the recurring
  Sequoia/Tahoe re-prompt → UI shows "Needs re-approval") only when `previous == .granted`. The app
  polls `refreshPermissions()` ~1×/second while Settings is open, so on the SECOND poll after a
  lapse `previous` was already `.lapsed` (not `.granted`), the condition failed, and the `else`
  overwrote it with the raw probe value (`.denied`/`.notDetermined`). Net: the "Needs re-approval"
  warning flashed for a single poll, then reverted to "Not granted" — defeating the exact
  never-granted-vs-lapsed distinction `.lapsed` exists to draw, right when the user needs the nudge
  to re-approve. The existing tests missed it because none refreshed a third time. Fixed: treat
  `.lapsed` as "was granted" too, so a lapse stays sticky across repeated ungranted polls; a fresh
  `.granted` from the probe still wins and clears it. Pure Core, behind the `PermissionProbe` seam,
  one-line condition change + 2 tests (sticky across 3 polls; re-grant clears it).
- **[RESOLVED 2026-06-30] Cold-launch glyphs never filled in — the bar showed app-icon fallbacks
  until an incidental refresh.** Reproduced on-device with a live signalable instance: on a cold
  launch the menu-bar glyphs don't composite into the capturable display image for ~tens of seconds
  (measured ~60s this session: launch 15:31:30 → first glyphs 15:32:30), but the launch warm-up (its
  clean pass + a fallback pass 220ms later) and the in-loop capture retries (≤6×180ms, bailing after
  2 stalled) ALL finish within ~1.5s — every one captures 0 glyphs. Nothing then re-captured until an
  incidental event (screen-param change, user open, diag) happened to run after the compositor warmed,
  so the bar sat on app-icon fallbacks. (This is the corrected diagnosis of the old "deterministic
  0/N / wallpaper-only" note — falsified because warm captures DO pull real glyphs.) Fixed with a
  small, bounded set of escalating warm-up retries: pure `WarmUpRetrySchedule` in Core (offsets
  2s/5s/12s/25s/45s/70s — bracketing the measured ~60s on both sides, escalating, ≤6 so the privacy
  indicator flashes at most a handful of extra times) consumed by `CosmeticHideEngine.scheduleWarmUp-
  Retries`/`fireWarmUpRetry`. Each retry runs ONE more `runCaptureSequence` warm-up pass, but only
  while `hasIncompleteGlyphs` is true — the set self-cancels the instant glyphs complete, and
  `cancelWarmUpRetries()` drops the rest when the user opens the bar, a reconcile takes over, the app
  is paused, the bar is disabled, or on uninstall. Rides the existing serialized `captureChain`/epoch
  machinery (reuses the exact launch warm-up closure), so it can't race a refresh or capture under an
  open panel. **Load-bearing subtlety (caught by the verification workflow):** `install()` calls
  `warmUpFloatingBarCache()` (which arms the timers) and then `reconcileHiddenItems()` synchronously
  — and reconcile *cancels* the pending retries (its own reveal→move→capture supersedes them). So for
  a user WITH saved Hidden intent (exactly the bug's configuration), the first-armed set is wiped at
  T+0. The bridge therefore **re-arms** at the END of reconcile's own sequence (`reconcileHiddenItems`
  L548-549: `if bar.hasIncompleteGlyphs { scheduleWarmUpRetries() }`) — reconcile's capture is just as
  cold (~1.5s) and lands the same 0/N, so the escalating retries are armed *after* it and fire across
  the warm-up window. On the warm path glyphs are already complete there, so nothing re-arms. Pure
  schedule + 4 tests (bounded ≤6, strictly escalating, positive, window straddles the measured
  warm-up). Design adversarially verified via workflow (Approach A; verifiers confirmed rides-chain /
  self-cancels / bounded AND surfaced the reconcile-cancels-the-bridge hole, which the committed code
  closes via the re-arm). *RESIDUAL — NOT fully on-device-verified: a relaunch landed glyphs=3
  autonomously, but the compositor was already warm, so it did NOT exercise the true cold path. The
  one configuration that matters — a cold-from-BOOT launch with saved Hidden intent + Accessibility
  granted, watching the log for a `glyphs=N` landing on a re-armed retry rather than an incidental
  event — is unverified from this rig and is the real proof still owed before this is fully trusted.*
- **[RESOLVED 2026-06-30] REGRESSION (introduced by `02a7cc8`): 7 real third-party items vanished
  from the floating bar ("No hidden items" while the menu bar was near-empty).** User-reported with a
  screenshot; reproduced from live `CGWindowListCopyWindowInfo` enumeration — 7 status windows pushed
  off-screen at x=-804…-605, all reporting raw `owner="Control Center"`, yet the bar showed nothing.
  Root cause: `02a7cc8` added the display name `"Control Center"` to `ImmovableItems
  .denylistedOwnerLabels` to protect the *real* Control Center from being MOVED — correct for the move
  path, which attributes snapshots to their true owner FIRST. But `HiddenItemsResolver.hiddenItems`
  (the floating-bar resolver) runs on RAW, pre-attribution snapshots (`captureAndCache` calls
  `attribute()` AFTER the resolver), and on Tahoe (FB18327911) raw `kCGWindowOwnerName` is the bogus
  blanket `"Control Center"` for MANY genuine third-party items. So the resolver's `!isImmovable`
  filter (a dormant no-op on raw labels since `5a06887`, which `02a7cc8` accidentally activated)
  dropped all 7. They were cosmetically hidden but unreachable. Fixed by splitting the predicate:
  `ImmovableItems.isImmovable` (full, for ATTRIBUTED callers — the move planner + Settings picker) vs
  new `isImmovableOnRawSnapshot` (reverse-DNS ids + title fragments only, NO display-name label) for
  the raw resolver; `hiddenItems` now calls the raw-safe variant. The real Control Center is excluded
  from the hidden set by POSITION (it lives right of the anchor) and the move path's denylist is
  untouched, so CC still can't be moved. Pure Core + 3 tests (raw "Control Center" third-party items
  kept; raw-safe still drops reverse-DNS/titles; full vs raw split pinned). Design adversarially
  verified via workflow (Approach B — split predicate — chosen over remove-filter and
  attribute-first; the latter would have tripled hot-path AX cost). **CONFIRMED ON-DEVICE
  2026-06-30:** relaunched the fixed build standalone; the resolver now reports `3 hidden -> 3
  deduped` (vs the old binary's "No hidden items"/0), and the diag attributes all three correctly —
  Neru, Karabiner-Menu, ACME (each `rawTitle:"Item-0"` → real `attributedOwner`), exactly the
  genuine third-party items the buggy build dropped as "Control Center". The inverted control-item
  order also self-healed on launch (anchor=470/divider=454 → 471) so the anchor returned on-screen.
- **[RESOLVED 2026-06-29] The immovable-items bundle-id denylist never matched, so Control Center
  could be moved.** `ImmovableItems.denylistedBundleIDs` holds reverse-DNS ids
  (`com.apple.controlcenter`, …), but `MenuBarItemSnapshot.ownerBundleID` is populated with a
  *display name*, not a bundle id — both at enumeration (`SystemWindowServer` uses
  `kCGWindowOwnerName`) and at attribution (`AXAttributionProvider` uses `localizedName` / a module
  title). A display name can never equal a reverse-DNS id, so the entire bundle-id branch was dead:
  the only thing actually protecting system items was the title-fragment list, and on Tahoe
  `kCGWindowName` is the generic "Item-0", so that's weak too. Net effect: a Control-Center item
  could pass `key != nil && !isImmovable` (`FloatingBarController` ~L595) and show up as a movable,
  toggleable row — and moving it corrupts the bar, exactly what the denylist exists to prevent.
  Fixed by adding a `denylistedOwnerLabels` set (display names) checked alongside the bundle-id set;
  it contains just `"Control Center"`, the exact string `AXAttributionProvider` already treats as
  canonical (`app.name == "Control Center"`), so it's a known invariant, not a guess. Pure Core,
  strictly protective (can only make *more* items immovable — worst case is today's status quo), +2
  tests (display-name immovable; filter drops both display-name and reverse-DNS forms). The bundle-id
  list is kept (a no-op today) for any future caller that sets a real id. **Residual** (see "Needs
  hardware verification"): other system owners (Spotlight, Now Playing) and the localized Control
  Center *module* labels (Wi-Fi, Battery, …) need on-device observation of their real attributed
  strings before they can be added safely — didn't guess them blind.
- **[RESOLVED 2026-06-29] The anchor right-click menu's items did nothing when clicked** (user-
  reported). `CosmeticHideEngine` is a plain Swift class, not an `NSObject` subclass. `NSMenu`
  defaults to `autoenablesItems = true`, which asks the target via `respondsToSelector:`/
  `validateMenuItem:` whether to enable each item before showing it — methods only an `NSObject`
  responds to. So AppKit couldn't confirm the engine handled the actions and left every action item
  (Pause / Settings / About / Quit) **disabled**, and a disabled item swallows the click. (The
  status-bar buttons were unaffected: `NSControl` dispatches its `@objc` action directly, bypassing
  validation.) Fixed by setting `menu.autoenablesItems = false` in `showAnchorMenu` — the action
  items stay enabled and dispatch over the same `NSApp.sendAction` path the buttons use; the
  informational header/status/version rows keep their explicit `isEnabled = false`. One-line glue
  fix, no logic seam to unit-test; only observable when the menu is shown on device.
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
- **[RESOLVED 2026-06-29] Superseded activation's AX sweep wasn't cancelled.** `AXActivator.activate`
  ran its synchronous AX IPC inside `Task.detached`, which has no parent and so **severs
  cancellation** — when the floating-bar caller superseded a slow activation (`currentActivationTask
  ?.cancel()`), the detached all-apps sweep kept grinding through every app at the full per-app
  timeout (1.5s × N), producing a result no one would use. Fixed by routing both detached calls
  through a `runCancellable` helper that bridges the caller's cancellation via
  `withTaskCancellationHandler` → `task.cancel()`, plus a `Task.isCancelled` early-exit at the top of
  `pressMatchingChild`'s per-app loop and a guard before the expensive all-apps sweep even starts.
  Behavior change is confined to the superseded path (whose result the caller already discards): it
  now stops early instead of blocking on unresponsive apps. When NOT cancelled, `runCancellable`
  reduces to exactly the old `await task.value` — byte-identical happy path. App-target async glue,
  no Core seam; correctness provable by inspection (existing 217 tests still green).
- **[RESOLVED 2026-06-29] `click()` could warp the cursor to the item and not restore it** if the
  pre-warp `CGEvent(source:nil)?.location` read returned nil. The warp onto the item was
  unconditional while the restore was guarded by `if let savedCursor`, so a nil read left the
  pointer parked in the menu bar. Fixed by reading `savedCursor` with a `guard` that throws
  `clickFailed` when nil — so we never warp without a paired restore point. The bail lands before
  `CGDisplayHideCursor`/its balancing `defer`, so there's no half-set cursor state to unwind, and a
  failed (recoverable) click beats a visibly-stranded pointer. Happy path (read succeeds — every
  real invocation) is byte-identical; the warp/restore are now provably paired. App-target glue, no
  Core seam; the guard's correctness is provable by inspection (existing 217 tests still green).
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
- **[RESOLVED 2026-06-28] `ItemControlStore` sets serialized in non-deterministic order.** The three
  `Set<String>` fields (`hiddenInMenuBar`, `shownInMenuBar`, `suppressedFromBar`) encoded via the
  synthesized Codable as JSON arrays in `Set`'s per-process iteration order, and `JSONEncoder
  .sortedKeys` sorts dictionary *keys*, not array *elements* — so re-exporting an unchanged layout
  produced a spurious diff every run. Fixed with a custom `encode(to:)` that writes the three sets as
  `.sorted()` arrays (dictionaries `barOrder`/`controlItemPositions`/`aliases` were already
  deterministic under `.sortedKeys`). On-disk shape is unchanged — still JSON arrays — so `init(from:)`
  reads new and old files identically; only the output order is now stable. Pure + 3 tests (byte-stable
  across insertion orders, arrays sorted ascending, round-trip still equal). Cosmetic, but the last
  Core-testable item in the backlog.
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
- **[PARTIAL, corrected 2026-09-10] Capture-sequence ownership guard.** `latestCaptureEpoch`
  prevents an older completion from restoring the divider after newer work is enqueued. The
  earlier claim that `awaitBounded` overtakes a wedged predecessor after eight seconds was wrong:
  structured task-group exit joins every child. The guard is useful, but does not fix a blocked
  native call; see the open timeout entry above. Cancellation behavior has hostless regression
  tests. Separately, reconcile still guards on panel visibility, not the broader `sectionInUse`,
  so an explicit Settings change can interrupt a native item's open menu.
- **[LOW, open] `colorAlpha` bbox test skips the first/last crop columns** (`IconCaptureService`
  ~L225): a thin colored badge touching the crop edge can lose its outer column. Impact bounded by
  the 2pt pad. Cleanup; hard to unit-test (needs pixel fixtures). Confirmed by the audit. NOTE
  (2026-06-30): re-read the code — the `p-4` "latent OOB row read at x==0" mentioned in older notes
  is NOT live: the `x > 0, x < w - 1` guard on L225 means `colorAlpha(p-4)`/`(p+4)` are never called
  at the edge columns, so there's no out-of-bounds access today. This is purely the cosmetic
  edge-column skip, not a safety bug — don't chase it as one. Also: the fix lives on the fragile
  capture keying path whose *visual* result can't be verified from this rig, so it's not a clean
  loop candidate even though the math could be characterization-tested.
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

- **Staged Settings interaction.** Off-screen tests exercise Apply/Discard/bulk controls, edited
  aliases across regrouping, preview overflow, and the full window's bounds. Pointer/keyboard focus
  transitions and VoiceOver navigation in an on-screen Settings window remain unverified. The
  schematic cannot qualify exact native ordering, spacing, or external-display moves.
- **Cursor concealment and Itsycal on external displays.** Repeat moves/activation on the failing
  external layout while unlocked, observe actual cursor visibility throughout the gesture, and verify
  both native representations and menu position. Capability flags, sampled endpoints, and fake relay
  tests do not prove absence of a brief visible movement. Never run native input probes while locked.
- **Hover reveal interaction.** Verify anchor-to-panel travel, first-click item activation, typing
  focus in Settings/another app, Reduce Motion, and external/stacked displays. Hostless tests cover
  ownership, cancellation, non-key ordering calls, and global-coordinate geometry, not native
  focus/first-click delivery or the feel of the 200ms dwell and 400ms exit grace. The setting stays
  off until explicitly enabled by the user.
- **Item hover highlighting.** Verify enter/exit across each row's text and empty space and each
  icon cell, in both click-opened and non-key hover-opened panels. Check first-click activation and
  highlight reacquisition after a cache refresh. Bitmap tests seed hover/press state; they do not
  claim to exercise native pointer delivery or appearance over the live material background.
- **Immovable denylist completeness** — the display-name guard protects "Control Center", AND (as of
  2026-06-30) the `immovablePIDs` set now catches **all Control Center modules at once by pid** —
  so the localized module labels (Wi-Fi, Battery, Sound, …) no longer need to be enumerated by string
  (that sub-item is RESOLVED by the pid approach; verified on-device that Battery/Audio modules at
  pid 22986 are excluded). What's still open: other system owners that run as their OWN process —
  Spotlight, Now Playing/`mediaremote`, `systemuiserver` — would need either their pids added to
  `ImmovableProcessIDs` or their display names confirmed on-device and added to `denylistedOwnerLabels`.
  Lower urgency now (they're not Control-Center-owned, so the common case is covered), but confirm the
  real attributed strings/pids on-device before adding — don't guess blind.
  - *Diag pulled 2026-06-30 14:01 (PID 5746, standalone, signalable): only 4 status windows present
    — the real CC audio cluster, Karabiner, ACME, and our own anchor. Spotlight / Now Playing / the
    CC modules simply aren't in the current bar to observe, so this stays blocked by **layout**, not
    by the rig — re-pull when those items are present. Also worth a recheck: that run's diag came
    back with `attributedOwner: "Control Center"` for ALL four (incl. Karabiner `rawTitle:
    org.pqrs.Karabiner-Menu` and ACME `com.amazon.ACME`), whereas an earlier-today diag attributed
    them correctly — smells like an Accessibility re-prompt lapse rather than a code regression.
    Don't touch attribution on this alone (it's the persistence-key landmine); confirm with AX
    freshly granted first.*
- **Recover a CC module the old buggy binary displaced left of the anchor** (found 2026-06-30, see the
  RESOLVED "Hide All" bug). A Control Center module dragged into the hidden section by the pre-fix
  thrash (live: Battery at x=1335 < anchor 1559) can't be moved back, because the planner now refuses
  all pid-22986 moves. Today's workaround is `killall ControlCenter` (or a reboot) — Control Center
  re-lays-out its modules on the right. A code fix would mean a ONE-TIME, narrowly-scoped "evict a
  CC-owned item that's wrongly left-of-anchor back to the right" path that bypasses the immovable-pid
  guard — but that re-enters un-relocatable-move territory and is only verifiable on-device (whether
  the CC module actually relocates can't be seen from this rig). Don't build it blind; needs a
  hardware session to confirm the move even takes before trusting it.
- **Control-item slot persistence via `Preferences.controlItemPositions`** — currently dead (see the
  doc-reconciliation gotcha): slots persist via AppKit's own UserDefaults keys + launch-repair, and
  this field is never written. If a deliberate status-item removal ever proves to lose the slot
  on-device (the original motivation), wire `CosmeticHideEngine` to write the live slots into this
  field via the already-present `onPreferencesChanged` seam and restore them in `install()`. Don't
  build it blind — it touches the control-item lifecycle (can't be seen from this rig) and must not
  fight `repairControlItemOrderIfNeeded`.
- **AXPress activation failure** — items advertise `AXPress` but it returns a non-success error;
  why is open (error-code logging was added). Synthesized click is the working default.
- **Capture cold-launch warm-up — RESOLVED 2026-06-30 (see the Bugs entry "cold-launch glyphs never
  filled in").** The earlier "deterministic 0/N / wallpaper-only capture-source" theory was falsified
  by live evidence (warm captures pull real glyphs); the true cause was timing — glyphs don't
  composite for ~tens of seconds after a cold launch, while the warm-up + retries all finished at
  ~1.5s. Fixed with bounded escalating warm-up retries. Kept here only as a pointer.

### Features not yet built (from the plan, roughly prioritized)

- **Settings window refinement (UX polish).** *(User feedback 2026-06-28: "looks like someone new
  built it… refine it and make it a proper app." Low priority, loop item.)*
  - **[DONE 2026-09-12, off-screen verified]** Staged Apply/Discard workflow, cached Menu Bar and
    Hidden Bar/List previews, persistent footer, and visible cached rows during refresh. Settings
    is 640x720; full-root tests include the identity header, tabs, unknown items, and error messages.
  - **[DONE this pass] App-identity header.** `SettingsView` now leads with an icon (the real
    `NSApp.applicationIconImage`) + app name + version banner above the tab strip — the concrete
    "no app identity" gap. The version string is composed by a pure, tested `AppInfo.displayVersion`
    (short + build → `"0.1.0 (1)"`, drops the parenthetical when build is missing/equal, `"—"`
    fallback). Window grew 580→620 to fit the header.
  - **[TODO, follow-up fires]** the rest is genuinely aesthetic and **can't be verified from this
    rig** (no menu-bar/Settings visibility): a sidebar/`NavigationSplit` layout instead of the tab
    strip, consistent section spacing/footnotes, an About area. These need either hardware QA or the
    user's eye — don't ship blind restyling. Bartender/Ice are clean-room visual references only.
- **Rich anchor right-click menu — IN PROGRESS (greenlit 2026-06-29).** The menu was Settings/Quit
  only; the user wants App name + version, a status line, Pause, About, Check for Updates, Restart.
  - **[DONE]** App name + version header (`CFBundleName`; version via the shared
    `AppInfo.displayVersion` so it matches the Settings header — both read `"0.1.0 (1)"`), a live
    **status line** (`Status: Paused / Ready / Working… / Collecting icons…`), an **About** item
    (standard AppKit about panel), plus the existing Settings/Quit — all in
    `CosmeticHideEngine.showAnchorMenu`. Status is backed by a pure, tested `AppStatus` enum in Core
    (`derive(paused:moving:capturing:updateAvailable:)`, precedence paused > update > move > capture
    > ready); the engine feeds it `reconcileInFlightCount`, `captureInFlightCount`, and `isPaused`.
    > Note (2026-06-29): the menu's action items needed `menu.autoenablesItems = false` to fire at
    > all — see the RESOLVED bug above; without it AppKit left every item disabled.
  - **[DONE] Pause** — a checkable menu item. Pausing reveals the hidden section in place (un-tucks
    the divider via `setHidden(collapsed: false)` + drives the state machine to `.shown`) and gates
    the automated triggers — left-click toggle, hotkey, and `reconcileHiddenItems` (the move) — with
    additive `!isPaused` guards, so while paused the bar behaves like a vanilla menu bar. Un-pausing
    collapses to baseline and re-applies saved per-item intent. DESIGN: `isPaused` is **session-only**
    (NOT persisted) — pause is an "I'm hunting for something right now" mode; a silently-paused app
    after reboot would be a worse surprise, and it keeps the change off the launch path. The gates
    are pure subtraction (the app does *less* while paused), so a bug can only mean "pause didn't
    fully take", never layout corruption — and it never touches the synthesized-move path.
  - **[TODO, follow-up fires]** **Restart** — relaunch the app (interacts with the single-instance
    guard in `AppCoordinator.anotherInstanceIsRunning`; sequence the new process carefully). **Check
    for Updates** — needs **Sparkle** wired (see below); `AppStatus.updateAvailable` already exists so
    the status line and that item will share one source of truth. Until Sparkle lands, it's omitted
    (not shown-disabled), since there's nothing to check.
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
- **Doc comments are reconciled with shipped reality (2026-06-28, extended 2026-06-29).** The old
  scaffolding `AGENT: implement…` comments in `LayoutConfig`/`LayoutTransferService` and a stale
  `SystemWindowServer` header claiming move/click "throw `notImplemented`" were corrected — all
  three are fully implemented (the move is verified on-device). 2026-06-29: also corrected two
  comments that described an *unimplemented* mechanism as if live — `Preferences.controlItemPositions`
  ("we cache them ourselves…") and `CosmeticHideEngine.onPreferencesChanged`. Neither is wired:
  control-item slots are persisted **directly** under AppKit's `"NSStatusItem Preferred Position …"`
  UserDefaults keys and self-healed on launch by `repairControlItemOrderIfNeeded`; `controlItemPositions`
  is never written (always `[:]`) and `onPreferencesChanged` is never invoked. Both are retained
  (the field is in the `Preferences`/`LayoutConfig` Codable shape; the callback is a pre-wired seam)
  but now documented as unused. If you add a new stubbed seam, prefer a real type
  (`WindowServerError.notImplemented`) over a comment that can rot out of sync.
