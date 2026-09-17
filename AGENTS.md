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

The user has authorized commits and pushes. The current priority (2026-09-15) is core hide/unhide
reliability, simpler Settings, and less manual testing. Earlier Bartender-parity work is a capability
inventory, not a mandate to restore removed tools. Track actual capabilities and verification gaps
in [PARITY.md](PARITY.md); do not equate a passing build with complete parity. Choose the best
engineering approach without asking for routine recommendations. Native behavior still requires
evidence, and the safety gates below still apply.

The user explicitly requested hover reveal again on 2026-09-11: an opt-in setting below Auto
Re-hide that opens the floating bar when hovering over the BKF icon and closes a hover-owned bar after leaving.
Click/keyboard ownership, Pause, and disabling the setting must remain authoritative.

The user requested staged placement and Settings previews on 2026-09-12. Hidden/Shown edits now
stay in a session-only draft until Apply Changes; Discard abandons only the draft. Preview rendering
must remain cache-only. Apply uses the existing serialized mover, not parallel native gestures.

Historical parity push: on 2026-09-12 the user asked for full Bartender 6 parity. Three
waves shipped (presets, triggers, groups, spacing, scroll reveal, onboarding, restart, update check;
Always Hidden tier, shortcut recorder + item shortcuts, menu bar styling, widgets;
notch make-room, Settings sidebar, export/login feedback). Those waves received hostless testing
behind the existing seams, not native qualification. Widgets were subsequently retired at the user's
request; the retained features still have the hardware gaps below.

Prior focus (2026-09-13): the user requested Items Apply Changes reliability only, not further
parity expansion. The native grab/drop sequencing defect below is fixed and verified for Alfred and
ACME on the built-in display. Other native layouts still need evidence; do not broaden this claim.

Earlier focus (2026-09-14): the user explicitly requested Settings search and moving Style directly
below Items. Search is Settings-only; the removed menu-bar Search panel and its global hotkey stay
removed. The Apply Changes safety and persistence constraints still apply.

Later on 2026-09-14 the user asked for General to be split up (it scrolled) and for a choice of BKF
icons. Both shipped; see Built. The installed Finder icon is never rewritten: that would need
re-signing the bundle, which would also invalidate granted TCC permissions.

On 2026-09-15 the user asked three things: whether two Layout modes are needed (no: Live is removed,
see Removed), why icons kept falling back to app icons (a fullscreen Space hid the menu bar; see
Built, "Icon reliability"), and to keep the screen-recording indicator out of the mirror (done: resolved
Control Center items are never mirrored, and the mirror follows current positions on open).

Later on 2026-09-15 the user requested a destination highlight after selecting a Settings search
result. This is implemented as a three-second outline of the matching setting or section, with
an enabling-switch fallback for hidden controls. See Built and `PARITY.md` for verification.

Earlier request (2026-09-15): simplify Settings and reduce the user's manual-testing burden. The user
expressly said widgets were unnecessary. The primary sidebar is now **General, Items, Style,
Behavior, Shortcuts, Advanced, About**. Advanced links to Presets/Triggers/Groups and holds spacing,
notch make-room, and backup; moving these controls does not disable saved rules/groups or retire
their hardware QA. Widget editing, status-item installation, and action execution are removed;
readable legacy widget data stays inert through load/import/edit/export. Do not re-add widget
runtime as parity work. General has an Arrange Items quick start, and About has project/help links.
The full suite for that change passed, including real-control workflows and AX geometry across every
Settings pane. Appearance review is partial: off-screen PNGs omit sidebar/glass and some material-backed
content. Live appearance, focus, and VoiceOver remain unverified; see the verification details below.

Latest request (2026-09-16/17): publish a public direct-download release using `asc`. The user selected
Developer ID-signed, notarized distribution rather than an App Store redesign. Developer ID issuance
through the API required the Account Holder; the user created the certificate using the generated CSR.
The matching private key and certificate are installed in Keychain, and the temporary plaintext key
was removed. `Scripts/release.py` and `Distribution/RELEASING.md` define archive/export, notarization,
DMG packaging, and Gatekeeper verification. Release enables Hardened Runtime and excludes debugger
entitlements/debug dylibs; the Utilities category is set. A universal Developer ID archive/export passed
signature and metadata checks. The full Release-optimized suite passed on arm64 and x86_64 under Rosetta:
**1097 tests, 1827 invocations per architecture, 3654 total**, zero failures/skips. Tests require the
command-only `ENABLE_TESTABILITY=YES` override for existing `@testable` imports. The shipping archive
does not use that override. **v0.1.0 (build 1) was published on 2026-09-17** from source commit
`f5357331f5b511ca0aa2d54510a92bdb4793907f`:
[release](https://github.com/aagrawal207/bar-keepers-friend/releases/tag/v0.1.0).
Apple accepted both the app and DMG with no issues; stapled tickets and Gatekeeper checks passed,
including a fresh download of the published DMG. The installed copy at `/Applications/BarKeepersFriend.app`
is running. After permission re-add/restart, it reports both permissions Granted, captures six real
glyphs, displays the floating bar, and passed two native reorder/restore moves on attempt one.
The user's current layout and preferences were preserved. The certificate transition needed renewed
TCC grants; do not mislabel that as a capture/mover code fix. No Playwright or other harness configuration
was changed. Release receipts and exact verification scope are recorded in `PARITY.md`.

Prior request (2026-09-16): polish Items dragging and support ordering within a bar. The implementation
adds precise insertion feedback, drag-edge scrolling, and owner-keyed order drafts alongside placement.
Apply/Discard include order arrows and drag reorders. Hidden/Always Hidden order uses existing
`barOrder` persistence in floating-bar mode; Menu Bar order and hidden-tier order in reflow mode use
one-shot, serialized native requests. No persistence key or attribution label changed. Six added
Settings workflows cover order and lifecycle behavior; the planner checks all 720 six-item permutations.
The full suite passed: **1097 tests, 81 suites, 1827 invocations**. After the user unlocked and showed
the menu bar, real Settings drags and four native Menu Bar reorder moves passed on the built-in display,
each native move on attempt one. The original full layout was restored. Ordering covers manageable
items, not exact adjacency around omitted system modules; an after-Maccy drop crossed Battery and was
restored with two before-drops. Native hidden-tier ordering, other displays, and pointer/focus/VoiceOver
remain unverified. See `PARITY.md` for the exact scope.

Prior request (2026-09-15): drag items between **Menu Bar, Hidden Bar, and Always Hidden** in
Settings; highlight the correct headings/controls after search; hide the native top-bar title
"Bar Keeper's Friend". The implementation uses three always-present horizontal destination strips,
the existing owner-keyed placement draft, an explicit shared search index, and transparent native
window chrome above an 820x720 useful content area. The sidebar identity remains visible. **The final
full build/test passed on 2026-09-16 (local date)**, including floating-bar-off drag/Apply, corrected
sidebar scrolling, conditional search targets, and group-name validation. Actual AppKit drag-session
delivery and live appearance/focus/VoiceOver remain hardware QA; see the verification record below.

**Testing direction (2026-09-14, from the user):** prefer fewer functional workflow tests over many
unit tests. A workflow test drives the real Settings UI, the real model, real persistence
(`PreferencesStore` in an isolated `UserDefaults` suite), and the real engine/mover together, and
mocks only OS boundaries that would otherwise move the user's cursor or rearrange the live menu bar
(status-item buttons, the event relay, screen capture). Cover edge cases inside those workflows
rather than as separate narrow tests. `AppIconWorkflowTests` and `NativeMoveTests` are the models
to follow. Do not delete existing unit tests wholesale; migrate a narrow test only once a workflow
test demonstrably covers its assertion.
The 2026-09-15 simplification extends real Settings workflows and records off-screen PNG attachments
for appearance review. Retire runtime-specific tests only with their retired implementation; keep
legacy persistence coverage. Off-screen rendering reduces manual checks but does not qualify live
focus, VoiceOver, native menus, movement, or capture.
The drag workflows mount the real Settings views and hit-test sources/destinations. Constructed mouse
events go directly to source handlers and are never posted; the native `beginDraggingSession` boundary
is intercepted. A unique pasteboard and fake `NSDraggingInfo` replace AppKit transport, while the real
model, isolated store, and engine exercise staging and Apply. A separate live session verified actual
same-bar drags and an empty-strip drop/Discard; live overflow/cancel animation remain hardware QA.
Current coverage and final results are in `PARITY.md`.
Configured-window tests must pass the scoped `configureWindow` hook before the first window-backed
render and compare window-relative rectangles. Search readiness requires the complete expected
highlight-region set within two seconds, before the three-second cue expires; retained native Form
AX rows can linger for 200–280ms. Direct-target and other-region exclusion assertions stay strict.

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
- **Do not re-add removed features** (menu-bar search, visible section dividers, or widgets) without an explicit
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

- Direct-release workflow: [Distribution/RELEASING.md](Distribution/RELEASING.md). Release artifacts use
  a separate `artifacts/` directory and a Developer ID identity, preserving the local Debug app.
- **Release verification (published 2026-09-17):** the full optimized suite passed on both arm64 and
  x86_64/Rosetta, 1097 tests and 1827 invocations per architecture (3654 total), zero failures/skips.
  Result: `artifacts/release-tests/Release-universal.xcresult.zip`, retained compressed with a passing
  archive-integrity check; extract before opening in Xcode or using `xcresulttool`. Existing
  actor-isolation/deprecated-AX warnings remain; Xcode's test-only `_Testing_CoreTransferable` framework
  lacks an x86_64 slice and produced a linker warning, but both architectures executed the full suite.
  A bare-metal Intel test is not claimed. An initial Release test build failed because `@testable` requires
  `ENABLE_TESTABILITY=YES`; the documented test command supplies it without changing shipping settings.
- **Release artifact cleanup (2026-09-17):** after recording verification, removed the dirty QA build,
  release/test build caches, failed test result, uncompressed passing result, duplicate DMG staging/download,
  notarization ZIP, and temporary smoke/CSR files. `artifacts/` fell from about 2.0 GiB to 535 MiB.
  Retained the complete passing result ZIP, final DMG, release archive/dSYMs, exported app, and
  notarization/checksum records. Full DMG/mounted-payload verification passed again after cleanup.
  The installed release is running from Applications; its strict signature and the retained Debug
  app's signature both passed. Local Debug `DerivedData` remains about 11 MiB.
- Generate project after adding/removing files: `xcodegen generate` (the `.xcodeproj` is
  gitignored — `project.yml` is the source of truth).
- Setup: [README source-build instructions](README.md#build-from-source) cover full Xcode.app,
  XcodeGen, the reader's own stable Apple Development identity, and standalone launch. The certificate
  pinned in `project.yml` belongs to the maintainer; others must override it for both build and test.
- Build from the repo root, with `BKF_SIGNING_IDENTITY` set as in README:
  `xcodebuild -project BarKeepersFriend.xcodeproj -scheme BarKeepersFriend -configuration Debug -destination 'platform=macOS' -derivedDataPath "$PWD/DerivedData" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$BKF_SIGNING_IDENTITY" build`
- Test: same command with `test`.
- **Prior verified build/test (2026-09-16 local date, within-bar order and drag polish):**
  `xcodebuild ... build test` passed on macOS 26.6.2 / Xcode 27.0: **1097 tests, 81 suites,
  1827 invocations**, zero failures or skips. Result: `bkf-order-full-03.xcresult` under
  `$TMPDIR/opencode` (transient). Incremental build metadata reported zero errors/warnings; the test
  result had one existing QoS warning in `GroupsSettingsTabTests`. Full-compilation actor-isolation
  warnings remain. Strict signature verification passed. Manual code/security review and diff checks
  completed; no independent review or automated security scan is claimed. The three scanners remain
  unavailable. The insertion-marker PNG was inspected; broader appearance limits remain.
- **Prior within-bar native verification:** real AppKit drags through Settings, Apply, and four item-relative
  native moves passed on the built-in display, with independent frame reads. Every move used one attempt.
  Original positions, including Battery's relative position, were restored; the empty Always Hidden
  strip accepted a real Maccy drop and Discard, ending with zero pending edits. See `PARITY.md` for
  probe corrections, the system-module adjacency limitation, and the remaining native QA.
- **Prior within-bar artifact cleanup:** after recording the results, this work's temporary test bundles, exported
  insertion PNG, live probe, build intermediates, and caches were removed. `DerivedData` is about 11 MB,
  retaining the signed Debug app. Strict signature verification passed again after cleanup. The
  `bkf-order-full-03.xcresult` reference is historical; that transient bundle is not retained.
- **Prior verified build/test (2026-09-16 local date, initial Items drag/drop, search targeting, window chrome):**
  `xcodebuild ... build test` succeeded on macOS 26.6.2 / Xcode 27.0: **1089 tests, 80 suites**,
  **1816 invocations**, zero failures or skips. The run includes all six drag directions with the
  floating bar both enabled and disabled. Result reference: `bkf-placement-drag-full-04.xcresult`
  under `$TMPDIR/opencode` (transient). `xcresulttool get build-results` reported `status: succeeded`,
  `errorCount: 0`, and eight pre-existing actor-isolation warnings in untouched
  `FloatingBarController.swift`. `PARITY.md` records the final command options and evidence scope.
- **Signature for that baseline:** `codesign --verify --deep --strict` passed on
  `DerivedData/Build/Products/Debug/BarKeepersFriend.app`.
- **Review for that baseline:** `git diff --check` and `git diff --cached --check` were clean. The read-only
  general reviewer, initially in a fresh context with follow-up reviews, **APPROVED** after fixes for
  trigger-editor cross-mode targets, empty-group membership targeting, and successful rename clearing
  prior validation. No different-model review was performed for this change; the dedicated-agent
  authentication failure below belongs to the historical baseline.
- **Security for that baseline:** manual security review completed. Automated scanner unavailability was
  reconfirmed in the unchanged environment (`scan_diff`, `semgrep`, and `gitleaks`); no automated
  security scan ran.
- **Appearance evidence for that baseline:** light/dark heading-pixel checks and real-control/AX geometry
  passed, including native sidebar row counts, full visibility, selection, configured-window controls,
  and the expanded Advanced footer. The footer fits with about 5pt remaining. No new full-window
  visual inspection is claimed; `cacheDisplay` still omits glass/sidebar and some material-backed content.
- **Latest prior passing build/test (historical baseline; 2026-09-15, Settings simplification/widget retirement):**
  `xcodebuild ... build test` passed on macOS 26.6.2 / Xcode 27.0: **1082 tests, 79 suites**,
  1794 invocations including parameterized cases, zero failures or skips. Strict
  `codesign --verify --deep --strict` passed on
  `DerivedData/Build/Products/Debug/BarKeepersFriend.app`.
- **Historical review for that baseline:** `git diff --check` and `git diff --cached --check` were clean.
  A fresh-context, read-only general reviewer approved the staged diff with no findings. The dedicated different-model
  review failed infrastructure authentication before reviewing; no different-model review completed.
  Manual security review was completed. `scan_diff`, `semgrep`, and `gitleaks` were unavailable via
  `command -v`, so no automated security scan ran.
- **Historical appearance review for that baseline:** the full suite generated 26 off-screen PNGs.
  Representative inspection was partial because `cacheDisplay` omits sidebar/glass and some
  material-backed content. AX geometry and real controls passed across all panes. See `PARITY.md`
  for the inspected views and remaining visual QA.
- **Historical baseline, before the Settings simplification/widget retirement:**
  2026-09-15, macOS 26.6.2 / Xcode 27.0, **1112 tests, 81 suites**, 1819 invocations including
  parameterized cases, zero failures or skipped tests. That built app also passed
  `codesign --verify --deep --strict`. These are not counts or verification of the current changes.
- **Prior artifact cleanup (2026-09-16, initial drag/search/chrome work):** completed after recording the results above and in `PARITY.md`.
  This work's temporary test bundles, exported PNGs, diagnostic probes, build caches, and intermediates
  were removed. `DerivedData` is about 11 MB, retaining `Build/Products/Debug/BarKeepersFriend.app`;
  its strict signature verification passed again after cleanup. Result-bundle references are historical;
  those transient files are not retained.
- Adapter tests only: append `-only-testing:BarKeepersFriendAppTests` to the test command. Their
  `BKF_TESTING` compilation condition keeps synthetic diagnostics console-only; production logging
  is unchanged. AppKit hide-animation completion still produces pre-existing actor-isolation
  compiler warnings on a full compile.
- Sign: reuse your stable Apple Development identity by SHA-1 to help preserve TCC permissions
  across rebuilds. Never ad-hoc (`-`) — it re-prompts every launch.
- All git on this Mac needs `-c core.hooksPath=/dev/null` (git-defender). Never `git push`
  unless asked; never force-push / rewrite pushed history. Main branch: `main`.

### Running + observing (no Xcode in the loop)

Run the app **standalone**, not via Xcode Run — an Xcode-launched process is parented to
`debugserver`, sits in state `SX`, and **cannot be `pkill`ed or signalled**; only Xcode's Stop
(⌘.) clears it. A standalone launch is parented to `launchd`, state `S`.

- Launch from the repo root after the README build:
  `open "$PWD/DerivedData/Build/Products/Debug/BarKeepersFriend.app"`
- **Diagnostics (`kill -USR1 <pid>`):** refreshes the mirror, then writes
  `~/Library/Logs/BKF-diag.json` (deep AX dump + attribution per item) and
  `~/Library/Logs/BKF-bar.png` (rendered panel). Async + deep AX inspect — wait ~12–16s, don't
  `rm` around it. The PNG is how to *see* what the user sees.
- `kill -USR2 <pid>` toggles the bar (for screenshotting).
- `BKF_DUMP_CROPS=1` dumps raw pre-keying crops plus `BKF-full.png` (quarter-size full frame) and a
  `full frame ... mean luma strip=/upper=/lower=` log line. `open` drops the environment; set it with
  `launchctl setenv BKF_DUMP_CROPS 1`, launch, then `launchctl unsetenv`. `BKF-diag.json` also carries
  `menuBarVisibility` and per-item `isOnScreen`/`hasGlyph`. A strip of 0 with a lit rest of the frame
  means the bar is hidden (fullscreen Space); do not chase it as a capture bug.
- Runtime log: `~/Library/Logs/BarKeepersFriend.log`.

## Built (done)

- **Notarized direct-download release (2026-09-17).** Public v0.1.0 includes a universal DMG and
  SHA-256 checksums. `Scripts/release.py` provides archive/export, resumable notarization, signed DMG
  packaging, and mounted-payload/Gatekeeper verification; `Distribution/RELEASING.md` documents it.
  The installed Developer ID build passed the limited live checks in `PARITY.md`. Automatic Sparkle
  updating remains unimplemented; the existing manual latest-release check now has a public release.
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
- **Apply move sequencing (2026-09-13, adapter + built-in-display verified).** The mover waits up to
  250ms for observed grab movement before releasing, then polls placement for up to one second after
  the initial 120ms settle instead of retrying during control animation. Off-bar release frames cannot
  count as success or receive recovery clicks. Submitted downs retain a balancing up on interruption
  or observation failure. Six native Alfred/ACME batches completed all ten moves on their first attempt;
  a standalone restart also applied saved Alfred Hidden intent on its first attempt. See the bug entry
  and `PARITY.md` for the reproduction, tests, and remaining limits.
- **Global toggle hotkey** — ⌥⌘B via Carbon `RegisterEventHotKey` (no Accessibility prompt).
  Keyboard-opened bar persists until re-toggled (doesn't auto-dismiss).
- **Opt-in hover reveal (2026-09-11, pure + adapter-tested).** Settings > Behavior has
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
  unfinished icons wait for lifecycle/display/placement refreshes and, since 2026-09-15, for the
  debounced check after the bar closes or the Space changes; there is still no idle refresh timer
  and no freshness guarantee at the moment of reopen (opening itself never captures).
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
  Settings, Restart, Check for Updates, Quit.
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
- **Staged placement (introduced 2026-09-12, original pure + adapter + rendering verification).**
  Hidden/Shown and Hide All/Show All edit an owner-keyed `ItemPlacementDraft` without persistence,
  enumeration, capture, or native movement. Apply merges only edited placements into current
  preferences once; identical saved intent requests a fresh reconciliation, never trusting cached
  flags as proof of native success. Discard leaves saved intent alone. Reversals preserve absent
  intent, and choosing the observed side can replace an opposing saved request while paused.
  Partial failures remain observed and retryable; repeated Apply cannot replace an active batch.
  Drafts survive Settings close/reopen within the session, but not app restart. Successful import
  replaces the draft; failed/cancelled import does not. Aliases save separately and survive row
  regrouping without overwriting a newer rename.
  "After Apply" projects merged saved-plus-draft intent; "Last Observed" uses loaded observations,
  with unknown placement separate. The original inert schematics are superseded by the drag editor
  below. These are manageable-item representations, not exact screen replicas. Historical off-screen
  tests covered actual controls, cached pixels, overflow, aliases, unknown placement, and window fit
  with read/placement errors. Current useful Settings content is 820x720 below native chrome. Test
  windows never order on screen; pointer/VoiceOver feel and external-display placement remain native QA.
- **Within-bar ordering and drag polish (2026-09-16; full suite + limited native verification passed).**
  The editor accepts same-tier drops and shows an insertion line over glyphs or empty strip space.
  Its registered `NSView` container owns the SwiftUI host and a separate, noninteractive AppKit marker.
  This avoids adding unsupported subviews directly to `NSHostingView`. A drag image is centered at the
  pointer; the source and owner siblings dim. AppKit periodic drag updates scroll crowded strips at
  their edges. No standalone scrolling timer is installed. A same-position drop succeeds without a draft.
  Source window and source-owned token checks reject wrong-window and substituted-source payloads.
  `ItemOrderDraft` stages owner-keyed ordering; siblings share a slot. Reversals and membership changes
  clear redundant order edits. Order survives fresh native window IDs. Apply persists hidden-tier order
  through existing `barOrder` keys; the arrows also stage. Show in bar and names still save independently.
  Menu Bar order, and hidden-tier order with the floating bar off, use an ephemeral order request on the
  existing serialized placement chain. Combined placement/order Apply uses one write and one pass.
  Order-only Apply leaves observed tiers alone and reports any pre-existing unmet placement separately.
  `ItemOrderPlanner` keeps a longest increasing subsequence and moves the remaining items across a live
  reference. The reference is deliberately on the wrong side: the existing native mover can return early
  for an item already on the requested side without establishing adjacency. The controller checks both
  the full-edge tier membership and final order, with a fixed gesture budget and fresh reads between moves.
  Pause, interruption, and failures retain native order for retry in this session; successful tiers clear
  individually. Import or a replacement saved arrangement supersedes the request. Native order is not a
  new persisted policy and is not continuously enforced. After unlock, real Settings drags, four native
  Menu Bar reorder moves, and an empty-strip drop/Discard passed. All native moves succeeded on attempt
  one, and the original full layout was restored. Exact adjacency around omitted system modules is not
  guaranteed. Workflow names, metrics/logging scope, and remaining evidence are recorded in `PARITY.md`.
- **Initial Items drag-and-drop arrangement (implemented 2026-09-15; hostless verification passed 2026-09-16).**
  `SettingsPlacementPreview` always shows three stacked horizontal destination strips: Menu Bar,
  Hidden Bar, Always Hidden. Empty strips remain drop targets, including with a vertical floating
  list or the floating bar disabled. Cached glyphs and unknown-placement names have an AppKit
  `SettingsPlacementDragSourceView`; the initial `SettingsPlacementDropView` was an `NSHostingView`
  registered for drops, so both glyphs and empty areas resolve to the destination ancestor.
  A custom pasteboard type carries only an opaque one-use UUID nonce, never owner keys or aliases.
  External/wrong-model sources and non-move masks are rejected before reading the pasteboard;
  malformed, stale, replayed, and same-tier payloads are rejected. The source's outside-application
  operation mask is empty. A valid drop calls the existing owner-keyed draft setter; siblings sharing
  an owner follow the choice. Apply persists once and uses the existing serial mover; Discard clears
  the draft. That version changed tiers only; the within-tier ordering extension is described above.
  Grouped items remain group-controlled, keyless sources cannot drag, and unknown placement remains
  selectable. Suppressed glyphs stay reachable and dimmed in the editor without enabling Show in bar.
  The existing filtered `placementPreview` property is preserved; the editable UI explicitly calls
  `placementPreview(includingSuppressed: true)`.
  Refresh, row placement edits, Apply/Discard, successful import, saved placement/group changes, and
  Items pane exit invalidate the model's drag session. Failed/cancelled import preserves it. Dragging
  and search add no metrics, telemetry, screen capture, or native placement work.
  Three new `StagedPlacementIntegrationTests` workflows passed. Together they cover all six directions
  with the floating bar enabled/disabled, suppression/siblings, unknown/grouped/keyless items,
  rejection/replay, cancellation, refresh, navigation, import, and one persisted serial Apply through
  real mounted views/model/store/engine. Unposted mouse-down/drag/up
  handlers exercise clicks and motion below/above the 4pt threshold, with the cached image used for the
  drag image. Native source/destination hit tests verify ancestor routing. OS transport is intercepted
  at the boundaries described under Testing direction. Actual session delivery/cancel animation and
  live appearance remain unverified; see `PARITY.md` for the final result and scope.
- **Hide All / Show All** stage all applicable owner choices in the same draft, including explicit
  choices for unknown placement. Buttons disable only when staging would be a no-op. One Apply
  submits the whole mixed-direction batch through the existing serialized reconciliation.
- **Settings search (introduced 2026-09-14).** A native search field
  below the sidebar identity filters pages by their names and setting keywords, including disabled
  controls. Matching ignores case/accents, requires every word, and prioritizes exact page/heading/
  control labels over keyword matches through the shared index described below.
  Typing keeps the current pane mounted and preserves Items drafts without extra item reads or writes.
  Result buttons, including the current page, and Return navigate and clear the query; blank/unmatched
  Return does nothing. Escape, the clear button, and external tab requests clear search. Marked-text
  commands remain with the input method. Query history is disabled. Search does not filter item names,
  scroll the detail pane, or move keyboard focus. Style is directly below Items. Advanced children remain directly
  searchable, including parent-qualified queries such as "Advanced Wi-Fi"; destination highlights
  are described below. Useful content is 820x720 with a 180pt sidebar. `ScrollViewReader` resets the
  sidebar's first-row anchor when the result set changes, fixing a retained 37pt offset that clipped
  General after clearing search. Workflows assert actual native row count, full visibility, and selected
  row identity. The current index/chrome passed the 2026-09-16 full suite; see `PARITY.md`.
- **Settings search destination highlights (heading/control correction hostless-verified 2026-09-16).**
  Selecting a result, including the current page, outlines the matching setting or section for three seconds.
  `SettingsSearchTarget.Entry` shares explicit labels, aliases, and section context between page
  filtering and highlight selection. `SettingsSearchSectionHeading` renders the same heading labels.
  Exact page/section/control names win over keyword matches. Page/parent qualifiers are removed only
  as whole tokens, once each, preserving names such as "Style Reset Style" and "Shortcuts Item shortcuts".
  "Permissions", "Icons", "Startup", "Menu bar spacing", "Hidden items", "Closing the bar", and
  "Reveal gestures" target their headings; "Permissions Accessibility" targets the permission row.
  "Items Menu Bar", "Hidden Bar", and "Always Hidden" target the editor's tier headings.
  Page-qualified queries such as "Style opacity" target the setting; equally strong matches can
  highlight several regions. Page-name-only queries highlight the page heading. Conditional fallbacks
  target the specific enabling control: Gradient for its end color, Border for its color, and the
  relevant floating-bar/rehide/spacing/shortcut switch. Closed editors and empty libraries point to
  Add Rule, Save Current Layout, or Create Group as appropriate. In an open trigger editor, unavailable
  cross-mode New/Edit/Add/Delete targets resolve to its visible heading or action; an empty condition
  list directs Remove Condition to Add Condition. A group with no member rows targets its own header
  for membership queries. These fallbacks preserve unsaved editor state. Visible disabled controls stay disabled;
  search does not enable them or open an editor. A new query, another page, or an external tab request
  clears the cue; repeated selections restart its lifetime without remounting the pane. The outline
  and tint add no layout space and ignore pointer input. Reduce Motion disables the fade, increased
  contrast thickens the outline, and accessibility custom content exposes "Settings search: Match"
  without replacing a control's existing help or value. The original four workflows in
  `SettingsSearchTests` covered 34 destination queries, conditional controls, cancellation/repeat
  timing, and actual light/dark pixels; those are historical coverage figures before the hierarchy
  update. Current workflows require the target itself to carry the match, exclude other highlighted
  regions, and check heading pixels for Permissions/Icons without painting neighboring controls. They
  also exercise new/edit trigger-editor destinations. The harness uses a real isolated `PreferencesStore`
  and real engine with counted item-provider/capture/status-button seams; search preserves Items drafts
  and performs no preference writes, moves, or capture. These checks passed in the 2026-09-16 full suite.
  No detail-pane auto-scroll or keyboard-focus jump was added. On-screen VoiceOver delivery and the
  feel of the fade remain native QA.
- **Settings window chrome (implemented 2026-09-15; hostless verification passed 2026-09-16).**
  `SettingsWindowController.configureWindow` hides the native title text, makes the titlebar
  transparent, removes its separator, and uses `.fullSizeContentView`. The AppKit title remains
  available as window metadata; BKF's sidebar identity is visible. Native close/minimize buttons and
  titlebar dragging are retained above the full 820x720 useful content area. Content-background
  dragging is off so it cannot compete with item drags. `SettingsWindowChromeTests` uses both the
  production window constructor and real configured off-screen windows to check safe-area sizing,
  traffic-light/sidebar/search clearance, a titlebar drag hit, one-time creation, close/reuse, position,
  and selected pane/deep-link retention. A scoped hook configures test windows before their first
  window-backed render; all panes confirm 820x720 useful content with window-relative geometry.
  The expanded Advanced footer fits with a tight margin of about 5pt. Earlier transient invalid geometry
  came from late test-host configuration, not production clipping. These checks passed in the full suite;
  live chrome, focus, and VoiceOver remain QA.
- **Settings simplification + About (2026-09-15, prior hostless workflow/geometry verification).** Seven
  primary rows: **General, Items, Style, Behavior, Shortcuts, Advanced, About**. The Advanced hub has
  buttons for Presets/Triggers/Groups, followed by spacing, notch make-room, and backup. Each child
  has a back-to-Advanced button and keeps Advanced selected in the normal sidebar. Existing retained
  child identifiers and `requestedTab` deep links remain usable; a search result can open a child
  directly and highlight its controls (including "Advanced Wi-Fi"). General contains Arrange Items,
  launch at login, and permissions. Behavior groups hidden-bar, closing, and reveal-gesture controls.
  Advanced refreshes permissions for the relocated notch warning even if General was never opened.
  Native grouped forms share a compact icon/title/purpose header; empty preset/trigger/group pages
  use cards. About renders the selected runtime app artwork and bundle version, with explicit links
  to the GitHub project, issues, and MIT license. It does not rewrite the installed icon.
  Navigation-only actions perform no preference writes, moves, or capture. Items, Shortcuts, and Groups retain
  their legitimate item reads; entering Advanced does not eagerly mount its children. Saved presets,
  enabled rules, and groups retain their behavior and outstanding hardware QA.
  `SettingsSearchTests.quickStartAdvancedToolsSearchAndAboutPreserveAnUnappliedDraft` adds an
  empty/populated workflow over the real UI/model/store/engine, including General's Arrange Items,
  an unapplied Items draft, child/back navigation, qualified search, and exact About-link URLs via
  injected `OpenURLAction`. `SettingsSidebarTests` checks all seven primary rows, parent selection,
  child routing, light/dark pane bounds, and richest configuration-pane fits. These checks passed in
  the prior simplification full suite, which generated 20 light/dark pane PNGs and six
  expanded-configuration PNGs.
  Representative appearance review is partial: `cacheDisplay` omits sidebar text/icons, glass, and
  some material-backed Items/Advanced-child content, while Form contents are readable. AX geometry
  and real controls were verified across all panes for that baseline, including omitted regions.
  Expanded Advanced controls/error text fit close to the bottom. Full-window appearance, focus, and VoiceOver remain
  unverified. No native input or capture mechanism changed; see `PARITY.md` for review details.
- **Settings split + BKF icon choice (2026-09-14, historical layout; icon workflow-tested).** The
  earlier split reduced General's ten sections by introducing Behavior and Shortcuts. A temporary
  Placement pane went with Live mode. Spacing/backup and then notch moved to Advanced in the later
  simplification above. `SettingsSidebarTests.bottommostControlIsVisibleWithoutScrolling` caught
  Behavior/Style overflow during those earlier arrangements; the prior simplification configuration-pane
  bounds passed, with the partial appearance-review limits above.
  Style gained an **Icons** row: a menu-bar symbol pop-up (five SF Symbols, `AppIconChoice.MenuBarSymbol`)
  and five app-artwork themes (`AppIconChoice.AppTheme`, Ocean is the shipped icon; others redraw the
  same sparkle-and-pill mark on a different gradient at runtime via `AppIconRenderer`, mirroring
  `Scripts/render_icon.swift`). Persisted as `Preferences.appIcon` with per-field lenient decoding, so
  a future symbol name degrades only that field. The anchor image is applied through
  `CosmeticHideEngine.applyAnchorArtwork` only when the symbol changes (test seam `setAnchorImage`);
  the app image reaches the Settings header, About page, the About panel (explicit `.applicationIcon` option),
  and `NSApp.applicationIconImage` for alerts. **The installed Finder icon is never rewritten**; the
  Settings note says so. Ocean's fallback never reads `NSApp.applicationIconImage` (this feature sets
  it, so it would echo the current theme). `AppIconWorkflowTests` drives the real Settings controls,
  real `PreferencesStore` in an isolated defaults suite, and the real engine: choose both icons,
  verify one write per edit and one anchor image, zero placement/capture work, an unapplied Items
  draft and aliases intact, then a fresh store/model/engine reads the choice back and no draft.
  Native rendering of the pop-up's menu items and the anchor's live appearance are hardware QA.
- **Icon reliability (2026-09-15, workflow-tested + hidden path live-verified).** The user's
  "icons keep falling back" was a hidden menu bar, not compositor timing: every capture since
  09-14 13:40 returned an opaque black strip while the rest of the display captured fine
  (`BKF_DUMP_CROPS` now also writes `BKF-full.png` with per-band luma; that is how this was found),
  because the user works in a fullscreen Space and `kCGWindowIsOnscreen` was false for every status
  window, Clock included. Three launches that day happened in that Space; each cached six fallbacks
  and cache-only opens never replaced them. `MenuBarItemSnapshot.isOnScreen` (pure
  `MenuBarVisibility.of(anchor:displayXRange:)`) now drives four behaviors: (1) a pass whose anchor is
  on its display but off screen refreshes membership only, with no reveal and no ScreenCaptureKit
  call (`capture: menu bar hidden; skipping reveal`); (2) `activeSpaceDidChange` and the bar closing
  each run one 1.5s-debounced `refreshFloatingBarCacheIfStale`, which asks for a capture only when
  `needsCapture || cachedMirrorIsStale`, so a settled cache never flashes the items; (3) `show()`
  prunes the mirror to what is tucked right now, so an item the system moved back beside the anchor
  (the privacy indicator does this) leaves the mirror on the next open; (4) Control Center modules
  whose owner Accessibility RESOLVED are excluded from the mirror and Settings, while an unresolved
  item (still carrying Tahoe's blanket pid) stays reachable, so the 02a7cc8 regression cannot recur.
  `GlyphStore` remembers the last captured glyph per attribution label under `~/Library/Caches`,
  written only for resolved owners; a remembered glyph stands in on the next launch but counts as
  incomplete so this launch's own capture replaces it. `MirrorReliabilityWorkflowTests` (4 workflows)
  drives the real engine and controller over `FakeWindowServer` with a scripted screenshot closure.
  Live: the relaunch inside the fullscreen Space logged the skip and made zero capture requests.
  The installed v0.1.0 release captured 6/6 real glyphs on the visible built-in bar after permission
  renewal/restart. Automatic recovery after leaving fullscreen without a restart still needs evidence.
  The screen-recording indicator is permanent here because DisplayLink Manager records the screen.
- **App icon** — a custom mark in `Sources/App/Assets.xcassets/AppIcon.appiconset` (a white
  menu-bar pill with three item dots, a left "tuck" chevron = BKF's hide control, and a cleaning
  sparkle, on a teal→blue squircle — the Bar Keepers Friend pun). Rendered by `Scripts/render_icon.swift`
  (pure Core Graphics, no SVG toolchain needed) at the 10 standard macOS renditions; wired via
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. Verified in the built bundle (`AppIcon.icns` +
  `Assets.car`, `CFBundleIconName=AppIcon`, `assetutil` lists all renditions). Matters even for an
  agent app: the Settings header and About surfaces render BKF's runtime artwork
  (previously the blank generic icon). *Large/mid sizes verified by eye here; the in-Settings/About
  appearance is review-only (no Settings visibility from this rig).*

- **Organization, appearance, and convenience tools (introduced 2026-09-12/13; historical pure +
  adapter + rendering coverage, native QA pending).** Retained features use lenient/lossy
  `Preferences` fields and opt-in defaults. Moving their Settings pages does not turn off existing
  saved configuration. Widgets are retired, as recorded under Removed.
  - **Presets** (`LayoutPreset`, `PresetLibrary`; Settings > Advanced > Presets; anchor-menu submenu with the
    active preset checked). Applying replaces `itemControls` only and runs the normal placement path.
  - **Triggers** (`TriggerRule`, `TriggerEvaluator`, `TriggerMonitor`; Settings > Advanced > Triggers). Battery,
    charging, battery-below, low power, Wi-Fi, frontmost app, external display, time-of-day/weekday.
    A matching rule applies its preset and remembers the prior arrangement in `triggerState`; the
    baseline is restored when no rule matches or the rule/preset is deleted. Evaluation is idempotent;
    trigger applies use `apply(preferences:userInitiated: false)` so they defer like launch placement
    (never close an open menu or prompt for Accessibility). Sources are armed only for the conditions
    in use; a 30s poll exists only while a Wi-Fi/battery rule exists. An unapplied Items draft is
    discarded when a trigger/preset changes the saved sets, with a footer notice.
  - **Groups** (`ItemGroup`, `ItemGroupLibrary`, `GroupStatusItemsController`; Settings > Advanced > Groups).
    Grouped owners are forced Hidden through `ItemGroupLibrary.effectiveControls` (placement, change
    detection, Items rows, previews) and reachable from a `BKFGroup-<uuid>` status item whose menu
    activates members from the glyph cache. Items rows for grouped owners are disabled ("In group").
  - **Menu bar item spacing** (`MenuBarSpacing`, `MenuBarSpacingService`; Advanced page). Writes the
    global-domain `NSStatusItemSpacing`/`NSStatusItemSelectionPadding` (ByHost + AnyHost) only on an
    explicit change; launch never removes values set elsewhere. Needs app relaunch/logout to show.
  - **Scroll/swipe reveal** (`ScrollRevealRecognizer`, `ScrollRevealMonitor`; opt-in below hover).
    Global+local scroll monitors (no Accessibility), one effect per gesture, 400ms cooldown.
  - **Onboarding** (`Onboarding*`): shown once for genuinely fresh installs (no saved store), never
    for upgrades. Welcome, placement explanation, permissions with live chips, done.
  - **Restart** (`RestartService`: detached `/bin/sh` waits for our pid to exit, then `open`) and
    **Check for Updates** (`UpdateCheckService`: manual GET of the GitHub latest release, no polling)
    in the anchor menu; `AppStatus.updateAvailable` is fed by the manual check.
  - **Always Hidden tier**: `ItemPlacement { shown, hidden, alwaysHidden }`, store key
    `alwaysHiddenInMenuBar` (omitted when empty). The `BKFAlwaysHidden` divider is created lazily
    only when some owner has that intent; plain reveal (click/hover/scroll/hotkey) keeps it tucked;
    Option-click reveals both tiers (reflow) or appends an "Always hidden" group to the floating bar.
    Only intent-backed owners live in the tier; a stray item that physically lands past the divider
    is mirrored as plain hidden. Planner output is byte-identical without the divider. Items rows use
    a three-segment picker plus Show-in-bar (immediate) and bar-order controls (staged until Apply).
  - **Live layout mode**: shipped 2026-09-12, removed 2026-09-15 (see Removed). Placement applies at
    launch (floating-bar mode), on Apply Changes/Retry, on preset/trigger/import intent changes, on
    display change (floating-bar mode), on unpause, and through `resumePendingPlacement`.
  - **Shortcuts** (`HotkeyAssignments`, `HotkeyRecorderView`, `ShortcutsSettingsSection`): a recorder
    for the toggle shortcut with system-reserved/conflict detection, and per-item shortcuts (owner
    key -> combo, ids 1000+, cap 32, toggle wins conflicts) that reveal and activate one item;
    inactive in reflow mode. Carbon registration is behind a `HotkeyRegistrar` seam.
  - **Menu bar styling** (`MenuBarStyle`, `MenuBarStyleGeometry`, `MenuBarStyleOverlayController`;
    Settings > Style): tint/gradient/opacity/shape/border/shadow drawn by one per-display overlay
    window at `kCGMainMenuWindowLevel - 1`, mouse-transparent, excluded from icon capture. Honors
    Reduce Transparency. Whether level 23 renders behind Tahoe's bar content is a hardware question.
  - **Notch make-room** (`NotchOverflowPlanner`, `NotchOverflowCoordinator`; Advanced page, default
    Never): when a revealed hidden section would be clipped by the notch (reflow or activation), the
    shown items nearest the anchor are swapped left of the section's leftmost item and put back
    before every collapse (toggle, activation rehide, auto-rehide, Option-click, pause, reconcile,
    and quit via `applicationShouldTerminate` -> `.terminateLater`). Never overlaps a placement batch.
  - **Settings sidebar**: `NavigationSplitView` with a fixed 180pt sidebar (identity header at top)
    and an icon/title/purpose detail header; useful content 820x720 below native titlebar controls.
    The native title text is hidden. Primary pages: General, Items, Style,
    Behavior, Shortcuts, Advanced, About. Presets/Triggers/Groups are Advanced children, independently
    searchable. `SettingsView(model:initialTab:)` and `requestedTab` remain the navigation API.
  - **Export/login feedback**: export distinguishes cancel from write failure; Launch at login shows
    requires-approval / not-registered notes with an "Open Login Items..." deep link.

## Removed (intentionally — don't re-add without asking)

- **Native Settings title text (2026-09-15).** The duplicate "Bar Keeper's Friend" title is hidden
  in transparent native chrome. The sidebar identity and AppKit window metadata remain; native
  close/minimize and titlebar dragging are retained. Configured-window checks passed in the 2026-09-16
  full suite; live appearance remains hardware QA.

- **Widgets (2026-09-15, user said they were unnecessary).** Removed `WidgetsSettingsTab`,
  `WidgetStatusItemsController`, `WidgetActionRunner`, and their AppCoordinator wiring. No widget
  status items or actions are installed/executed. The `widgets` preferences key, `MenuBarWidget`,
  and legacy action Codable shape remain for load/import/edit/export compatibility; readable
  payloads remain inert, including parameters the former editor rejected. Existing lossy decoding,
  duplicate/cap handling, and name/symbol fallbacks remain. Tests for the retired runner, controller,
  and editor were removed with those implementations; legacy `MenuBarWidgetTests` remain, and new
  `WidgetCompatibilityWorkflowTests` cover persisted/imported literal JSON through real Behavior
  edits, save/reload, and export while preserving aliases and an Items draft. These checks passed
  in the prior simplification full suite.
  Widget-only native QA (status-item placement, action launch, Shortcuts process, mailto handoff)
  is retired with those paths; this does not retire group, trigger, or per-item-shortcut QA.

- **Live layout mode** and the Layout mode picker (2026-09-15, user asked "do we need two?"). Live
  re-applied saved placement after any app launched or quit, gated on pointer idleness. It was
  hardware-unverified, could move the pointer while the user worked, silently needed Accessibility,
  and the user could not tell the modes apart. AppKit restores a relaunched item's slot and a
  brand-new item lands hidden but reachable, so the remaining behavior covers the cases that matter.
  `layoutMode` in old stores/exports is ignored on decode; never re-add the key with a new meaning.

- **Menu-bar Search panel** + its ⌥⌘F hotkey — user found it confusing. Settings-only search is separate.
- **"Show section dividers"** toggle — divider is now an invisible mechanism only.
- **Previous reveal-on-hover implementation** - removed because the user did not want it and its
  off switch did not fully stop it. The replacement explicitly requested on 2026-09-11 is opt-in
  and cancellation/ownership-tested; see Built for its verification scope.

## Remaining work

### Bugs (open)

- **[FIXED 2026-09-16, hostless workflow-verified] Clearing Settings search could clip General.**
  The native sidebar retained a 37pt scroll offset after search results changed row heights.
  `SettingsSidebar` uses `ScrollViewReader` to reset the first-row anchor when the result set changes.
  `SettingsSearchTests` checks actual native row count, full row visibility, and selected-row identity
  through filtering and clearing. This scrolls only the sidebar; destination-page scrolling is unchanged.
- **[FIXED 2026-09-16, hostless workflow-verified] Some conditional search destinations had no target.**
  Trigger-editor New/Edit/Add/Delete queries now resolve across editor modes; an empty condition list
  redirects Remove Condition to Add Condition. Membership queries for a group with no member rows
  target that group's header. Existing `SettingsSearchTests` workflows cover these states, transitions
  back to populated controls, and preservation of unsaved names/conditions and the Items draft.
- **[FIXED 2026-09-16, hostless interaction-verified] Group rename validation could disappear or linger.**
  AppKit's identical-value echo after Return cleared an invalid-name error; the binding now ignores
  that echo. Successful rename explicitly clears prior validation, including an unchanged-text retry
  after the conflicting group is deleted. `GroupsSettingsTabTests.renamingCommitsOnReturnAndKeepsAnInvalidNameLocal`
  drives the mounted fields and checks exactly four preference snapshots across valid edits, conflict
  removal, and retry. Invalid names remain local, with their error visible across Return and blur.

- **[FIXED 2026-09-13, adapter + native verified for Alfred/ACME] Apply could drop before the native
  grab took effect.** Current logs showed Alfred exhausting five attempts in consecutive mixed batches
  despite successful relay submission. A supervised A/B test reproduced three immediate-drop failures
  and three successful drops after observing grab movement, with the original layout restored each time.
  A relay echo confirms forwarding, not that the owner has entered drag state. A successful drop also
  left the divider animating for about 500ms, so the old 120ms check retried valid moves prematurely.
  Bounded grab and placement polling fix these paths without changing event routing or saved identity.
  `NativeMoveTests` exercises the real mover with fake events, frames, clocks, and cursor operations:
  13 tests / 29 cases, including delayed release, permanently off-row frames, cancellation, read errors,
  and bounded failure. The initial 19 failing cases passed after the fix; independent review prompted
  the additional off-row release coverage. Native mixed batches used the production controller/mover
  with independently confirmed owners; all ten moves succeeded, and starting frames were restored.
  The restarted app independently attributed and hid Alfred successfully, ending with `failed=false`.
  This does not establish external-display reliability, universal cursor invisibility, or recovery
  from a non-returning synchronous native read. Automated security scanners were unavailable; the diff
  received manual security review.
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
  **2026-09-15:** the built-in-display 0/6 runs had the same signature and were a hidden menu bar
  (fullscreen Space). Re-check this one with `BKF_DUMP_CROPS=1` and `menuBarVisibility` in
  `BKF-diag.json` before assuming a different cause; a remembered glyph now also masks it visually.
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
- **[RESOLVED 2026-09-13, adapter + rendering-tested] Export errors and login approval need clearer
  feedback.** `LayoutTransferService.exportLayout` returns `ExportOutcome { saved, cancelled, failed }`
  with injected panel/writer; the model shows the failure reason. `SettingsModel.loginItemStatus` +
  `loginItemNotice` surface `.requiresApproval` / lost registration with an "Open Login Items..."
  button behind a `LoginItemManaging` seam. Real `SMAppService` transitions remain hardware QA.

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

### Needs hardware verification (off-screen tests do not qualify native behavior)

Moving tools into Advanced changes their discoverability, not their saved configuration or native
mechanisms. Their hardware obligations remain. Widget-specific runtime paths and their hardware
checks were removed; legacy widget persistence and its compatibility workflows passed the prior
simplification full suite. Current drag/search/chrome hostless checks passed on 2026-09-16; the native
limitations below still apply.

- **Retained parity-tier native behavior (historical hostless coverage from 2026-09-13).**
  - Always Hidden: first creation of `BKFAlwaysHidden` lands left of `BKFHidden`; three-slot launch
    repair on a real defaults file; two expanded dividers (memory, no flash of tier items on a plain
    reveal); Option-click detection via `NSApp.currentEvent`; native relay drops relative to the tier
    divider; the "stray item lands leftmost" premise.
  - Triggers: IOKit power-source callbacks, CoreWLAN delegate (SSID is nil without Location
    permission, so connection is inferred from station mode + RSSI), time-of-day at DST boundaries.
  - Groups: status-item slot seeding right of the anchor, Command-drag persistence, member-menu
    presentation via `performClick`, and activation through the shared item path.
  - Spacing: `defaults -currentHost read -globalDomain NSStatusItemSpacing` after Apply; effect
    after relaunching a menu-bar app; whether ByHost or AnyHost is the domain AppKit reads.
  - Styling: whether a level-23 overlay is visible behind Tahoe's transparent bar; interaction with
    "Show menu bar background", Reduce Transparency, auto-hidden bar, fullscreen Spaces.
  - Notch make-room: a drop whose reference is a third-party (possibly notch-clipped) window; partial
    overlap tolerance at `auxiliaryTopRightArea.minX`; flicker/latency inside the 5s activation deadline.
  - Shortcuts: real Carbon registration of 1+N slots; recorder first-responder capture (Command-W
    must not close Settings while recording); item shortcut fires reveal -> click -> rehide.
  - Restart/update: LaunchServices settle vs the single-instance guard and the native update-check
    alert. The public latest-release API was verified to return v0.1.0 after publication.
  - Onboarding: live permission transitions, presentation, and VoiceOver.

- **Simplified Settings and About (2026-09-15).** The prior full suite passed real-control workflows
  and AX geometry across all panes. PNG review is partial because `cacheDisplay` omits sidebar/glass
  and some material-backed content; full-window appearance remains unverified. Native material appearance, sidebar
  non-collapsibility under drag, pointer/keyboard focus, child/back navigation feel, VoiceOver, and
  real browser handoff still need live checks. Injected `OpenURLAction` tests verify exact URLs.
  The About PNG's version 16.0 comes from the test runner's `Bundle.main`, not the production app.
  A smaller sidebar and retired widgets reduce the QA surface without qualifying retained native tools.
- **Staged Settings interaction.** Off-screen tests exercise Apply/Discard/bulk controls, edited
  aliases across regrouping, editor overflow, and window bounds. The new mounted drag workflows
  hit-test real sources and destination ancestors, but intercept `beginDraggingSession` and use
  unposted events plus fake `NSDraggingInfo`. Separate live checks verified same-bar session delivery,
  an empty-strip drop/Discard, and four Menu Bar reorder moves. Live overflow/cancel animation,
  pointer/keyboard focus, and VoiceOver remain unverified. Configured-window geometry and heading
  pixel checks do not qualify live titlebar/material appearance. The `cacheDisplay` glass/sidebar
  omissions persist; no fresh full-window appearance claim is made. The schematic cannot qualify
  exact spacing or external-display moves. Order covers manageable items; adjacency around omitted
  system modules is not guaranteed. Native ordering within hidden tiers still needs evidence.
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

- **Sparkle auto-update.** The manual GitHub check and Developer ID-signed, notarized DMG are in place.
  The signed update feed and automatic updater remain. Public v0.1.0 was released on 2026-09-17;
  README also retains source-build instructions with the reader's own stable signing identity.
- **A future Mac App Store edition** requires a public-API, sandboxed redesign. The current
  unsandboxed/private-API architecture conflicts with App Review 2.5.1 and 2.4.5(i); this is not a
  claim that a redesigned edition is permanently impossible. See README's Apple source links.
- **Per-Space / per-display styles and presets.** Bartender applies styles per menu bar; BKF uses
  one style and one arrangement for all displays.
- **Menu-bar search** stays removed at the user's request (see Removed); Settings search is built.
- **Restart / Check for Updates** shipped 2026-09-12 (anchor menu); the earlier "Rich anchor menu"
  in-progress notes are superseded by the Built entry above.

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
