# Bartender Parity

Last reviewed: 2026-09-16, local date (direct-release preparation; optimized tests passed on arm64 and
x86_64/Rosetta, notarization/publication pending; prior native ordering evidence remains limited).
Reference: [Bartender 6 product](https://www.macbartender.com/),
[release notes](https://www.macbartender.com/Bartender6/release_notes/), and
[support](https://www.macbartender.com/Bartender6/support/).

This is a capability and verification inventory, not a claim of full Bartender feature or native
behavior parity. The user's current priority is reliable hide/unhide, simpler Settings, and less
manual testing. Widgets were removed at the user's request on 2026-09-15; retained advanced tools
still run saved configurations and still need their hardware QA. The latest request adds staged ordering
within all three Settings bars, insertion feedback, and edge scrolling during drags.
Per-Space/per-display styles and presets and signed auto-update remain gaps. Direct-release packaging
is in progress; no downloadable release is claimed yet.
Menu-bar search stays removed.

The checklist distinguishes implementation, automated coverage, and native evidence. Passing geometry
or fake-backed tests does not prove that macOS opened a particular third-party menu, moved an item to
the requested slot, or rendered a cursor without flicker. The current drag workflows intercept AppKit's
actual drag-session boundary; they do not establish native event delivery. A separate live session
verified real Settings drags and four native reorder moves. The current full suite passed on 2026-09-16;
its scope and the native results are recorded below. Off-screen rendering still omits some
sidebar/material-backed content; it does not establish full-window appearance.

## Core Workflows

| Capability | Current State | Remaining Work |
|---|---|---|
| Permission-free hide/show | Implemented using BKF's own divider | Preserve this baseline through every change |
| Settings placement editor | Three always-present strips for Menu Bar, Hidden Bar, and Always Hidden; cached-icon/name drags stage placement and owner-keyed order. Insertion feedback and drag-edge scrolling guide drops. Apply uses real persistence and the serial mover; Discard clears both drafts. Real same-bar drags and a drop into the empty Always Hidden strip followed by Discard passed live | Live overflow scrolling, cancel animation, focus, and VoiceOver remain hardware QA |
| Per-item Shown/Hidden | Observed grab/placement polling; six built-in-display Alfred/ACME batches completed ten moves on the first attempt; saved Alfred Hidden also succeeded after restart | Itsycal failed on a 1920-point external display, then succeeded on the built-in display; external behavior remains open |
| Floating bar under a crowded menu bar | Cached icons, horizontal/vertical wrapping, off-screen hosting tests; glyphs remembered across launches; hidden-menu-bar captures are skipped; the mirror follows current positions on open and checks for refresh after close or a Space change; resolved Control Center items are excluded | The 09-14 fallbacks were a fullscreen Space, not timing. Live confirmation of `isOnScreen` on a visible bar, external-display capture, and cold-boot compositing remain hardware QA |
| Item pointer feedback | Shared row/cell hover and pressed highlight; light/dark, disabled, and sizing checks use off-screen AppKit drawing | Native enter/exit across label/whitespace and reacquisition after host replacement |
| Item activation | Positioned click with own-connection background concealment; interruption-safe optional AX path | Universal no-flicker behavior, menu compatibility, and external-display qualification |
| Hover reveal | Cache-only opens; optional captures revalidate after queue waits; ownership and non-key ordering tested | Native first-click delivery, focus, animation transit, display qualification, and freshness without intrusive capture |
| Keyboard access | Recorder for the toggle shortcut with system-reserved/conflict detection; per-item shortcuts reveal and activate one item (floating-bar mode) | Real Carbon registration of 1+N slots, recorder first-responder behavior, accessible navigation/dismissal |
| Reveal gestures | Click, hotkey, opt-in hover, opt-in scroll/swipe (one effect per gesture, cooldown) | Native scroll-direction feel and monitor routing over the live bar |
| Notch full access | Make-room in Settings > Advanced (default Never): tucks shown items nearest the anchor when a reveal is notch-clipped, restores before every collapse and before quit | Drop relative to a third-party window, partial-overlap tolerance, flicker/latency inside the activation deadline |
| Layout mode | One behavior: saved placement applies at launch, on Apply Changes, and on display change. The Live option (re-apply after app launch/quit) was removed on 2026-09-15 as confusing and hardware-unverified | Whether users miss automatic re-application for apps that relaunch |
| Display correctness | Placement re-reads controls; several coordinate fixes are tested | Explicit 2D display identity, negative-origin capture, stacked-display panel selection, and live external-display qualification |
| Native-work resilience | Pause/superseding/session interruption cancel safely; submitted downs retain balancing ups; interrupted placement stays pending | Native lock-transition qualification, Space/fullscreen/mouse-idle policies, and genuine recovery from non-returning calls |

## Organization And Distribution

| Capability | Current State | Remaining Work |
|---|---|---|
| Ordering | Same-bar drags and order arrows stage until Apply. Hidden-tier order uses existing `barOrder` persistence in floating-bar mode; Menu Bar order and hidden tiers in reflow mode use one-shot native requests. Four live Menu Bar reorder moves succeeded on attempt one; the original layout was restored | Native order covers manageable items, not exact slots among omitted system modules. Hidden-tier native order, other apps/displays, and continuous enforcement remain outside this verification |
| Multiple items from one owner | Coupled by the existing persisted owner key | A deliberate migration design before any independent identity scheme |
| Presets/profiles | Named presets (save current, apply, update, rename, delete) in Settings > Advanced > Presets and the anchor menu; saved arrangements remain usable | Per-display/per-Space presets; native verification of a preset apply is the same as placement |
| Triggers | Settings > Advanced > Triggers; saved enabled rules still apply presets and restore the baseline for battery, charging, battery-below, low power, Wi-Fi, frontmost app, external display, and time/weekday conditions | IOKit/CoreWLAN callbacks and DST boundaries on hardware |
| Groups/Always Hidden | Group editing is in Settings > Advanced > Groups; saved groups still install a BKF-owned member menu. Always Hidden retains its lazily created divider and Option-click reveal | Group slot seeding and member activation; tier-divider drops, two expanded dividers, stray-item premise |
| Widgets | Removed from UI/runtime on 2026-09-15 at the user's request; readable legacy data remains inert through load/import/edit/export | Keep legacy Codable and workflow compatibility coverage; widget-only native QA is retired, and reintroduction needs a new request |
| Styling | Tint/gradient/opacity/shape/border/shadow per-display overlay at level 23, excluded from icon capture | Whether the overlay is visible behind Tahoe's transparent bar; fullscreen Spaces; Reduce Transparency interplay |
| Spacing | Settings > Advanced; global `NSStatusItemSpacing`/`SelectionPadding` override with log-out guidance; explicit changes only | Which global-domain host AppKit reads; effect after relaunching apps |
| Settings navigation | Seven primary rows: General, Items, Style, Behavior, Shortcuts, Advanced, About; Presets/Triggers/Groups remain Advanced children. Real controls and AX geometry passed across all panes. Search-result changes reset the first sidebar row; native row count, full visibility, and selected-row identity are asserted | PNGs omit sidebar/glass and some material content; full-window appearance, live focus, and VoiceOver remain unverified |
| Settings window chrome | Native title text hidden, transparent titlebar with `.fullSizeContentView`; close/minimize and titlebar dragging retained above 820x720 useful content. Real constructor/configured-window sizing, clearance, creation/reuse/position/selection, and expanded-footer checks passed | Live appearance/focus/VoiceOver remain QA; the expanded Advanced footer has a tight margin of about 5pt |
| Settings search | Explicit shared heading/control index prioritizes exact labels, with whole-token page qualifiers and specific conditional fallbacks. Full-suite workflows passed direct-match, other-region exclusion, heading-pixel, cross-mode trigger, and empty-group checks. Search does not write preferences, move items, or capture; Items/Shortcuts/Groups retain their item loads | Live input-method/focus/VoiceOver checks remain; no item-name search or detail-pane auto-scroll |
| About | Runtime app artwork and bundle version; explicit GitHub project, issues, and MIT license links; exact URLs verified through injected `OpenURLAction` | PNG version 16.0 is the test runner's `Bundle.main` version, not the production app's; real browser handoff and on-screen accessibility remain native QA |
| Onboarding/login/backup | Fresh-install onboarding, live permission status, staged Apply/Discard with a cached arrangement editor; login approval feedback in General; layout import/export in Advanced | Real permission and `SMAppService` transitions; native onboarding presentation |
| BKF icons | Menu-bar symbol (5 SF Symbols) and app-icon theme (5 gradients on the shipped mark) chosen in Style > Icons; persisted leniently; applied to the anchor, Settings header, About, and alerts without re-signing the bundle | Live anchor appearance and pop-up rendering; the Finder icon is deliberately not changed |
| Updates/install | Manual GitHub release check and Restart; source builds use the reader's Apple Development identity. Developer ID is installed, and a universal Hardened Runtime archive/export passed signature and metadata checks. `Scripts/release.py` defines notarization, DMG packaging, and Gatekeeper verification | Notarization, final signed-app smoke checks, and public release are pending. Sparkle/signed automatic update remains unimplemented |
| Mac App Store | Current unsandboxed/private-API architecture conflicts with App Review 2.5.1 and 2.4.5(i); see [README's Apple sources](README.md#distribution-and-the-mac-app-store) | A future edition needs a public-API, sandboxed redesign and an eligibility assessment; it is not permanently ruled out |
| Capture privacy | Whole-display acquisition followed by local icon cropping | Qualify a narrower acquisition path; do not claim menu-bar-only acquisition today |

## Deliberate Differences

- macOS 26 only; no older-macOS compatibility layer.
- Menu-bar search and visible section dividers remain removed. Settings-only navigation search is available.
- Hover was previously removed; its new opt-in implementation follows the user's explicit request.
- Bartender Pro's additional shelf/media/calendar/file utilities are outside the menu-bar-manager
  scope unless requested separately.
- One style and one arrangement for all displays; Bartender styles each menu bar separately.
- Widgets are retired because the user found them unnecessary. Legacy data is preserved inertly;
  a historical feature checklist is not authorization to reinstall their runtime.
- Presets, triggers, and groups remain available under Advanced. Relocation does not disable saved
  rules/groups or retire their native verification obligations. Widget-only hardware paths are gone.
- Settings workflows and off-screen PNG review reduce the user's manual-testing burden. They do not
  establish actual AppKit drag-session delivery, native focus, VoiceOver, menu activation, capture, or
  movement correctness. The arrangement editor is a cache-only schematic, not a live menu-bar replica.

## Verification Gates

- Each change needs concrete reachability or a specified capability, regression tests, and an
  independent review proportionate to its risk.
- Native movement must be verified against live item/control frames, not event-post return values.
- Native menu behavior, visible cursor motion, cold boot, and display/Space transitions require
  on-device evidence before being marked complete.
- Never race a new native operation past an unfinished one merely to make a timeout appear fixed.
- Keep persistence keys, attribution-label construction, protected-item exclusions, and the
  permission-free baseline unchanged unless a separately justified migration is required.

## Direct-Download Release Preparation (2026-09-16)

The user selected Developer ID-signed, notarized direct distribution. The API could not issue a
Developer ID certificate without the Account Holder; the user issued one through the Developer portal
using the generated CSR. Its public-key digest matched the CSR, and the certificate/private key form
a valid Keychain signing identity. The temporary plaintext private-key file was removed.

Release-only settings enable Hardened Runtime and disable base debugger entitlements/debug dylibs.
The app category is Utilities. The existing Debug identity and app remain separate. A universal
Developer ID archive and export passed deep/strict signature validation, secure timestamp, entitlement,
bundle/version, and arm64/x86_64 architecture checks. No notarization or downloadable release is claimed
at this point. The repeatable workflow is in `Distribution/RELEASING.md`.

The full Release-optimized suite passed on macOS 26.6.2 / Xcode 27.0: **1,097 tests and 1,827 invocations
per architecture, 3,654 invocations total**, with zero failures or skips on arm64 and x86_64 under
Rosetta. Result: `artifacts/release-tests/Release-universal.xcresult`. An initial test build failed
because existing `@testable` imports require `ENABLE_TESTABILITY=YES`; that override is supplied only
to the test command, not the shipping archive. Existing actor-isolation/deprecated-AX warnings remain.
Xcode's `_Testing_CoreTransferable` test framework emitted a missing-x86_64-slice warning; both
architectures nevertheless ran the full suite. Each recorded the existing Groups Settings QoS warning.
Rosetta execution does not qualify bare-metal Intel behavior or the remaining native hardware cases.

Release preparation adds no app metrics or telemetry. Archive/export checks and optimized workflows
are verified; notarization, mounted-DMG checks, final signed-app smoke testing, and publication remain
pending. Playwright and other harness configuration were not changed.

## Within-Bar Order And Drag Polish (2026-09-16)

Same-bar drops are accepted. The insertion line tracks the selected gap over glyphs and empty strip
space. The registered destination is an `NSView` containing the SwiftUI host and a separate AppKit
marker; adding the marker directly under `NSHostingView` produced an AppKit runtime warning and was
replaced during verification. The marker ignores hit tests. The drag image is centered at the pointer,
and owner siblings dim together. Periodic AppKit drag updates scroll overflowing strips near their
edges; no timer remains after the drag. Same-position drops succeed without creating edits.

`ItemOrderDraft` stores session-only owner order alongside the placement draft. Apply and Discard
include ordering, including the existing arrows. Reversals clear redundant edits, and a refreshed
window ID keeps the owner's order. Show-in-bar and alias edits retain their independent save behavior.
The pasteboard still holds only a one-use UUID. The destination also verifies source window and
source-owned token identity before accepting a drop.

Hidden/Always Hidden order is saved through existing `barOrder` keys. Menu Bar order, and hidden-tier
order when the floating bar is disabled, uses an ephemeral engine request. Combined placement/order
Apply shares one preference write and one serialized pass. Order-only Apply leaves tiers at their
observed positions, including during the Applying preview. The controller reports pre-existing unmet
placement separately so ordering cannot masquerade as successful placement. Failed/cancelled work
retains the native request for Retry; completed tiers clear individually. A successful import or
replacement saved arrangement supersedes it. Native order is not a new persisted or continuous policy.

`ItemOrderPlanner` retains a longest increasing subsequence and moves other windows across a reference
on the wrong side. This is required because the existing native mover can return early for an item
already on the requested side, even with intervening icons. The controller uses live references,
checks full-edge tier membership and final order, and limits the total gestures. Attribution labels,
keys, the synthesized event relay, and cursor restoration are unchanged.

### Metrics and logging

| Output | Emitted when | Scope |
|---|---|---|
| Metrics/telemetry | None added | Drafting, drag feedback, and cache-only previews emit none |
| Existing `HiddenItemController` reconciliation log | Every pass, including zero order failures | Adds the bounded `orderFailed` count; native order errors use the existing local `DebugLog` path |

### Test coverage

The following six added workflows use the real mounted Settings UI, model, isolated `PreferencesStore`
where persistence is exercised, and engine/controller. Only OS transport, status items, capture, and
window-server behavior are replaced. The opt-in fake row reflow is a test model, not native evidence.

| Case | Workflow | Level |
|---|---|---|
| No-op, reversal, Discard, owner siblings, unchanged cache until Apply, one save, no native work for floating-only order, save/reload | `floatingOrderReversalsDiscardAndApplyKeepSiblingsAndRealCacheConsistent` | Functional workflow |
| Exact three-tier order, one serial pass/write, floating bar on/off, actual floating view content, unchanged placement sets | `allThreeBarsApplyExactOrderThroughOneSerialPass` | Functional workflow, two configurations |
| Order without saved placement, Pause, cancellation or failure, Retry, one-shot completion | `nativeOrderWithoutPlacementIntentSurvivesPauseAndInterruptedOrFailedApply` | Functional workflow, two outcomes |
| Crowded strip scrolling, gap marker bounds and pixels, noninteractive marker hit test, cancel/drop without native work | `crowdedBarsScrollDuringDragAndKeepInsertionFeedbackNoninteractive` | Functional workflow + off-screen bitmap |
| Opposing saved placement does not change tiers during order staging, Applying, or completion; explicit Retry handles remaining placement | `orderingAlonePreservesObservedTiersDespiteAnOpposingSavedPlacement` | Functional workflow, floating bar on/off |
| New window IDs preserve order, aliases persist independently, invalidated drag rejected, cancelled/failed import preserves Retry, successful import cancels it | `orderDraftSurvivesNewWindowIDsAndSuccessfulImportCancelsAnAppliedOrderRetry` | Functional workflow |
| All 720 six-item permutations reach the desired sequence with minimal wrong-side moves; duplicate/absent IDs and unchanged order | `ItemOrderPlannerTests` | Pure unit/property coverage |

The existing all-six-directions workflow also verifies combined placement/order Apply, and the mounted
row workflow verifies staged arrows alongside immediate Show-in-bar changes. Existing malformed/stale/
replayed-source, refresh/navigation, group, capture, and native-mover checks remain.

### Current verification record

**Full build/test passed:** 1,097 tests across 81 suites, 1,827 invocations, zero failures or skips,
on macOS 26.6.2 / Xcode 27.0. The final result was `bkf-order-full-03.xcresult` under
`$TMPDIR/opencode`, using the documented build command with:

```sh
xcodebuild ... \
  -resultBundlePath "$TMPDIR/opencode/bkf-order-full-03.xcresult" \
  -collect-test-diagnostics on-failure \
  COMPILER_INDEX_STORE_ENABLE=NO -quiet build test
```

Build metadata reported `status: succeeded`, zero errors and zero warnings for this incremental build.
The pre-existing actor-isolation warnings remain on a full recompilation. The test result recorded one
existing QoS warning in `GroupsSettingsTabTests`; no drag-container runtime warning remained.
`codesign --verify --deep --strict` passed on the built app. Manual code/security review and diff checks
completed. No independent review of this change is claimed. `scan_diff`, `semgrep`, and `gitleaks` were
unavailable, so no automated security scan ran. The insertion-marker PNG was inspected; full-window
glass/material appearance and VoiceOver remain unqualified.

### Live check (2026-09-16 local date)

The first preflight was locked. After the user unlocked and switched from fullscreen to a visible
menu bar, the new build ran standalone. A temporary Accessibility/CGEvent helper opened the real
Settings window, located its controls by accessibility identifier, and posted mouse drags through
AppKit's actual session transport. Apply ran the production engine/controller and event relay.
Independent native window reads verified the results on the 1512-point built-in display.

| Native move | Reference | Native x before → after | Result |
|---|---|---|---|
| Itsycal before ACME | ACME, window 84 | 1224 → 1158 | Attempt 1, one planned/succeeded move |
| Itsycal after Maccy | Maccy, window 54 | 1158 → 1300 | Attempt 1; manageable order correct, but Battery interleaved |
| Itsycal before Maccy | Maccy, window 54 | 1300 → 1192 | Attempt 1, one planned/succeeded move |
| Maccy before Itsycal | Itsycal, window 50 | 1288 → 1192 | Attempt 1, original full ordering restored |

The four requests ended with `failed=0`, `orderFailed=0`, and no pending work. Logs are dated
2026-09-17 02:12–02:29 UTC. Final native positions were ACME x=1158, Maccy x=1192, Itsycal x=1224,
Battery x=1320, Control Center x=1396, and Clock x=1438; the native anchor stayed at x=1126.
Settings returned to Last Observed with zero pending changes. A subsequent real drag of Maccy into
the empty Always Hidden strip created one draft; Discard returned it to Menu Bar without a native move.
The original order remained intact and Settings was closed afterward.

The first far-trailing-edge probe targeted x=1553 after the display configuration had changed to a
1512-point screen, and staged nothing. Another attempt found Ghostty covering the target. The helper
was corrected to check the active session, activate BKF, verify endpoint hit ownership, and use a
visible destination. These rejected probe attempts are not counted as successful drag delivery.

**Scope:** this establishes real glyph-to-glyph reorder drags, an empty-strip drop/Discard, and native
before/after moves for Itsycal/Maccy with ACME as a reference. The after-Maccy move passed the ordering
contract while putting Itsycal after Battery: omitted system modules are not part of the requested
order, so exact adjacency around them is not guaranteed. Two further moves restored Battery's original
relative position. Native hidden-tier ordering, overflow scrolling, cancel animation, other displays/apps,
focus/VoiceOver, and absence of cursor flicker still need evidence.

After recordkeeping, this work's temporary result bundles, exported insertion PNG, live probe, and build
caches/intermediates were removed. `DerivedData` is about 11 MB and retains the running
`Build/Products/Debug/BarKeepersFriend.app`. Strict signature verification passed after cleanup.
Result-bundle references are historical; those transient files are not retained.

## Initial Items Drag-and-Drop, Search Targets, And Window Chrome

This records the preceding implementation and its verification. The ordering extension above replaces
its same-tier rejection and immediate order arrows, and uses a registered container around the host.

The 2026-09-15 implementation replaces the inert Items previews with three permanently visible,
stacked horizontal destination strips: **Menu Bar, Hidden Bar, Always Hidden**. Empty tiers remain
available. The editor stays horizontal when the floating bar is a vertical list or is disabled.
Cached glyphs and unknown-placement names use `SettingsPlacementDragSourceView`; the destination
is the containing `SettingsPlacementDropView`, an `NSHostingView` registered for the custom drag type.
This puts the destination on the ancestor path for drops over glyphs as well as empty strip space.

The pasteboard contains one opaque, one-use UUID nonce, not an owner key or alias. External and
wrong-model sources, and sources without a move operation, are rejected before reading the pasteboard.
Malformed, stale, replayed, and same-tier payloads are rejected. The source advertises no operation
outside the application. A valid drop uses the existing owner-keyed draft setter, including its sibling
coupling. **Apply Changes** saves through the real preferences path and shares the existing serial
mover; **Discard** abandons placement edits. There is no within-tier drag reorder or direct native
menu-bar drag from this Settings gesture.

Group members remain group-controlled. Unknown-placement names can be dragged to select a tier;
keyless sources cannot drag. Icons suppressed from the floating bar remain dimmed and reachable in
the editor without changing Show in bar. `SettingsModel.placementPreview` keeps its existing filtering;
the editor opts into `placementPreview(includingSuppressed: true)`. Refresh, row placement edits,
Apply/Discard, successful import, saved placement/group changes, and leaving Items invalidate the model
drag session. Failed/cancelled import leaves it intact. Staged placement choices survive Settings
close/reopen within the session, but not an app restart.

Search filtering and destination selection share explicit `SettingsSearchTarget.Entry` labels, aliases,
and section context. `SettingsSearchSectionHeading` renders those same heading labels. Exact page,
section, and control names take priority over keyword matches. Page/parent qualifiers are removed as
whole tokens only once, so repeated words in "Style Reset Style" or "Shortcuts Item shortcuts" survive.
"Permissions", "Icons", "Startup", "Menu bar spacing", "Hidden items", "Closing the bar", and "Reveal
gestures" highlight their headings. "Permissions Accessibility" highlights the permission row;
"Items Menu Bar", "Hidden Bar", and "Always Hidden" highlight the respective editor headings.

Conditional controls have specific reachable fallbacks: Gradient for its hidden end color, Border for
its hidden color, and the appropriate floating-bar/rehide/spacing/shortcut enabling switch. A closed
trigger editor points to Add Rule; empty preset/group libraries point to their creation controls.
An already-open trigger editor exposes its own rule/condition headings and controls, with fallbacks for
unavailable targets from the other editor mode. A group with no member rows targets its own header for
membership queries. Search preserves the three-second cue, leaves disabled controls disabled, and does
not enable features or open editors.

`SettingsWindowController.configureWindow` hides the native title text, makes its background
transparent, removes the separator, and uses `.fullSizeContentView`. The AppKit title remains window
metadata and BKF's sidebar identity stays visible. Native close/minimize buttons and titlebar dragging
sit above the full **820x720 useful content area**. Content-background dragging is disabled so it does
not compete with item drags. The controller creates the window once and retains its position and
selected pane on reuse; an explicit tab request still navigates.

### Fixed defects and verification boundaries

- **Sidebar clipping after search:** the native list retained a 37pt offset after result-row heights
  changed, clipping General when search cleared. `SettingsSidebar` uses `ScrollViewReader` to reset
  the first-row anchor when results change. Tests check native row count, full visibility, and actual
  selected-row identity, rather than inferring native selection from a filtered accessibility list.
  No detail-pane auto-scroll was added.
- **Unavailable search destinations:** New/Edit/Add/Delete queries resolve to the visible trigger
  editor heading or action across modes. With no conditions, Remove Condition points to Add Condition.
  A group with no member rows supplies its header as the membership target; populated and not-running
  members use their own controls. Workflows preserve unsaved editor state and the Items draft through
  these transitions.
- **Group-name validation:** an identical-value AppKit echo after Return could erase the validation
  error. The input binding ignores that echo, and successful rename explicitly clears prior validation.
  The existing mounted rename workflow deletes a conflicting group and retries the unchanged text,
  checking exactly four preference snapshots and no invalid-name persistence.

Chrome tests use the scoped `configureWindow` hook **before the first window-backed render** and compare
window-relative rectangles. Earlier transient invalid geometry came from a late-configured test host,
not production clipping. Real constructors and all-pane checks confirm 820x720 useful content,
native-control/sidebar/search clearance, and an expanded Advanced footer that fits with about 5pt left.

Search tests wait for the **complete expected highlight-region set within two seconds**, before the
three-second cue expires. Native Form accessibility rows from the prior state were observed lingering
for 200–280ms. The complete-set wait retains direct-target and other-region exclusion assertions;
no assertions were weakened to accept partial or stale matches.

### Automated coverage (passed in the final full suite)

Three new workflows in `StagedPlacementIntegrationTests` use the real mounted Settings
view, model, isolated `PreferencesStore`, engine, and placement controller. Root hit tests must reach
the source and a registered destination ancestor over both glyphs and empty areas. Constructed
`NSEvent` mouse-down/drag/up events are **unposted** and passed directly to the mounted source handlers.
They check clicks and motion below/above the 4pt drag threshold, with the cached image used for the
drag image. The `beginDraggingSession` boundary is intercepted; a unique pasteboard and fake
`NSDraggingInfo` replace AppKit's session transport. Native menu-bar input/capture remain behind fakes.

| Coverage | Test | Level |
|---|---|---|
| All six tier directions, empty destination, absent-intent reversals, owner siblings, suppressed glyph reachability with filtered preview preserved, real Discard, one persisted serial Apply, in-progress drag rejection, store reload; Apply parameterized with floating bar on/off | `StagedPlacementIntegrationTests.mountedDragsStageEveryDirectionAndApplyOnePersistedSerialBatch` | Functional workflow |
| External/wrong-model/copy-only rejection before pasteboard reads; wrong type, malformed/missing/multiple items, stale/replayed tokens; superseded source cannot cancel its successor; row placement edit, cancellation, Discard, and retained drafts | `StagedPlacementIntegrationTests.mountedDropRejectsForeignMalformedStaleAndReplayedTokensWithoutLosingDrafts` | Functional workflow |
| Unknown placement through the real provider, keyless source rejection, pane exit/re-entry, suspended/cancelled refresh with cached rows retained, group control, saved intent replacement, failed/cancelled/successful import | `StagedPlacementIntegrationTests.unknownItemsRefreshNavigationAndPreferenceChangesRespectDragLifetime` | Functional workflow |
| Actual configured window and production constructor; configuration before first window-backed render, window-relative useful content/safe-area sizing, close/minimize/sidebar/search clearance, titlebar drag hit, lazy creation, close/reuse, retained position/selection, explicit tab requests, expanded-footer fit | `SettingsWindowChromeTests` | Hostless window lifecycle + geometry |
| Exact heading/control matches across panes, qualifiers, conditional fallbacks, cross-mode trigger editor and empty/populated condition lists, empty/populated/not-running group members, strict direct-match metadata and other-region exclusion, draft/persistence preservation | Expanded `SettingsSearchTests` workflows; `SettingsSidebarTests.sectionNamesAndSpecificControlsHaveDistinctSearchDestinations` | Functional workflow + matching assertions |
| Filtered and restored sidebar row count, full native row visibility, selected-row identity, and General reachable after clearing search | `SettingsSearchTests.searchResultsHighlightTheirDestinationsAcrossEveryPaneWithoutApplyingAnything` | Functional workflow + native table geometry |
| Invalid rename stays local across Return/blur; valid correction clears its error; conflict deletion followed by unchanged-text retry; exactly four expected preference snapshots | `GroupsSettingsTabTests.renamingCommitsOnReturnAndKeepsAnInvalidNameLocal` | Hostless interaction + model write assertions |
| Permissions/Icons heading pixels change without painting neighboring controls; stable bounds, light/dark and Reduce Motion; existing control highlight remains actionable | `SettingsSearchTests.highlightsPaintTheDestinationWithoutResizingOrDisablingIt` | Hostless bitmap + interaction |
| Three stacked bars remain available when empty, horizontal layout for both floating styles, bounded overflow; configured-window pane bounds and Items controls | `SettingsPlacementPreviewTests`, `SettingsViewTests`, `SettingsSidebarTests` | Hostless rendering + geometry |

Drag staging and search add **no metrics or telemetry, screen capture, or native item placement**.
The workflows assert no preference writes or native work from a drop/search. Explicit page navigation
retains the existing item reads for Items/Shortcuts/Groups. Apply retains the existing post-placement
capture when the floating bar is enabled; the passing workflow also covers it disabled.

### Verification results (2026-09-16)

The final local run **succeeded** on macOS **26.6.2** / Xcode **27.0**: **1089 tests across 80 suites,
1816 invocations, zero failures or skips**. It used the documented project/scheme/signing options with
the following final arguments (abbreviated command):

```sh
xcodebuild ... \
  -resultBundlePath "$TMPDIR/opencode/bkf-placement-drag-full-04.xcresult" \
  -collect-test-diagnostics on-failure \
  COMPILER_INDEX_STORE_ENABLE=NO -quiet build test
```

| Evidence field | Current result |
|---|---|
| Build result metadata | `xcresulttool get build-results` for `bkf-placement-drag-full-04.xcresult`: `status: succeeded`, `errorCount: 0`. Eight pre-existing actor-isolation warnings came from untouched `FloatingBarController.swift`. |
| Built-app signature | `codesign --verify --deep --strict` passed on the current `DerivedData/Build/Products/Debug/BarKeepersFriend.app`. |
| Diff and independent review | `git diff --check` and `git diff --cached --check` were clean. A read-only general reviewer, initially in a fresh context with follow-up reviews, **APPROVED** after the trigger cross-mode, empty-group membership, and successful-rename validation fixes. No different-model review was performed for this change. The prior dedicated-agent authentication issue is historical. |
| Security review | Current manual security review completed. Automated scanner unavailability was reconfirmed in the unchanged environment (`scan_diff`, `semgrep`, and `gitleaks`); no automated security scan ran. |
| Current appearance evidence | Light/dark heading-pixel checks and AX geometry passed, including all panes, real native sidebar rows, configured-window clearance, and the expanded footer. No new full-window visual inspection is claimed; `cacheDisplay` still omits glass/sidebar and some material-backed content. |
| Artifact cleanup | Completed after recordkeeping on 2026-09-16. This work's temporary test bundles, exported PNGs, diagnostic probes, caches, and build intermediates were removed. `DerivedData` is about 11 MB, retaining the runnable `Build/Products/Debug/BarKeepersFriend.app`; strict signature verification passed again after cleanup. Transient result-bundle references are historical; those files are not retained. |

### Remaining hardware evidence

Actual AppKit drag-session event delivery and cancellation animation remain unverified because the
hostless workflows intercept session creation. Live pointer/keyboard focus, titlebar/material appearance,
and VoiceOver still need limited hardware QA. Window geometry and heading-pixel assertions do not fill
the existing `cacheDisplay` omissions of glass/sidebar and some material-backed content. Native
menu-bar movement, capture, and external-display obligations remain as recorded for those mechanisms.

## Historical Verification Records

The dated results below describe their original code states, before the current Items drag/drop,
search-targeting, and window-chrome changes. The latest prior passing baseline is the Settings
simplification/widget retirement below. Counts, former page layouts, and retired widget test names
are historical records, not claims about the current tree. Current completion evidence belongs above.

### Settings Simplification And Widget Retirement

On 2026-09-15 the user asked for simpler Settings and fewer manual checks, and explicitly said widgets
were unnecessary. `SettingsView.Tab.sidebarTabs` exposes General, Items, Style, Behavior, Shortcuts,
Advanced, and About. `advancedTabs` holds Presets/Triggers/Groups; their existing identifiers and
`requestedTab` deep links remain usable. The Advanced hub mounts no child until selected. Its child
pages show a back-to-Advanced button and keep Advanced selected in the normal sidebar.

General now has Arrange Items, launch at login, and permissions. Behavior groups hidden-bar, closing,
and reveal-gesture controls. Spacing, notch make-room, and backup moved into Advanced; its own
permission refresh keeps the notch warning current without a visit to General. Native grouped forms
use a compact icon/title/purpose header, with cards for empty preset/trigger/group pages. About uses
the selected runtime artwork, bundle version, and explicit project/help/license links. It does not
rewrite the installed Finder icon. Search still highlights individual settings and sections, including
Advanced-qualified child queries, without enabling controls or opening editors.

`WidgetsSettingsTab`, `WidgetStatusItemsController`, `WidgetActionRunner`, and their AppCoordinator
wiring were removed. `MenuBarWidget`, `WidgetAction`, and the `widgets` preferences key remain for
compatibility. Readable action parameters are retained even when the former editor would reject them;
they cannot execute. Existing lossy decoding, duplicate/cap handling, and name/symbol fallbacks remain.
Tests for the retired runner/controller/editor were removed with those implementations. Legacy Codable
tests remain, and the new compatibility workflow uses literal JSON rather than generating its input
with the current encoder. Group installation and trigger monitoring remain wired to saved preferences.

#### Automated coverage (historical full-suite pass)

| Coverage | Test or artifact | Level |
|---|---|---|
| Empty and populated preset/trigger/group libraries; General's Arrange Items; staged Hide All; child/back navigation; Advanced parent selection; saved configuration and unapplied draft/aliases preserved | `SettingsSearchTests.quickStartAdvancedToolsSearchAndAboutPreserveAnUnappliedDraft`, parameterized over both library states | Functional workflow |
| "Advanced Wi-Fi" and preset search deep-links; About artwork/version; exact project, `/issues`, and `/blob/main/LICENSE` URLs requested only after pressing a link | Same workflow with real Settings UI/model, isolated `PreferencesStore`, real engine, and injected `OpenURLAction` | Functional workflow |
| Navigation-only actions produce no preference writes, retries, moves, clicks, capture, or divider/artwork changes; item reads counted for Items, Shortcuts, and Groups | `SettingsSearchTests` harness and expanded search workflows | Functional workflow |
| Seven primary rows, primary-row navigation from a child, stable child routing, parent selection, no eager sibling panes, and light/dark AX bounds across every pane | `SettingsSidebarTests`, `SettingsSearchTests` | Hostless interaction + AX geometry |
| Bottommost controls of richest configuration panes and error notes fit; the suite generated light/dark and expanded-state PNGs with the capture omissions described below | `SettingsSidebarTests`: `settings-<tab>-light.png`, `settings-<tab>-dark.png`, `settings-<tab>-expanded.png` Swift Testing attachments | AX geometry + partial bitmap review |
| Legacy saved preferences and imported layout JSON survive real Behavior edits, save/reload, and export; aliases and an Items draft survive; a fresh model has no session draft; no native work occurs | `WidgetCompatibilityWorkflowTests.legacyWidgetsSurviveSettingsEditsAndBackup`, parameterized over persisted/imported input | Functional workflow |
| Widget JSON keys/discriminators, readable payloads, malformed entries, old fallback rules, duplicates, and caps | Retained `MenuBarWidgetTests` | Unit/compatibility |

The workflow harnesses use real persistence and engine/model wiring with OS boundaries replaced by
fakes. Their windows remain off screen. About-link assertions intercept `OpenURLAction` and do not open
a browser. There are no new metrics, telemetry, native input gestures, or capture mechanisms in this
change. Moving retained tools changes their discoverability, not their runtime or hardware QA.
Widget-specific status-item/action/Shortcuts-process/mailto checks are retired with those paths.

#### Historical verification results (2026-09-15)

- **Full build/test:** `xcodebuild ... build test` passed on macOS 26.6.2 / Xcode 27.0:
  **1082 tests across 79 suites, 1794 invocations, zero failures or skips**.
- **Signature:** `codesign --verify --deep --strict` passed on
  `DerivedData/Build/Products/Debug/BarKeepersFriend.app`.
- **Diff/review:** `git diff --check` and `git diff --cached --check` were clean. A fresh-context,
  read-only general reviewer approved the staged diff with no findings. The dedicated different-model
  review failed infrastructure authentication before reviewing; no different-model review completed.
- **Security:** manual security review completed. `scan_diff`, `semgrep`, and `gitleaks` were
  unavailable via `command -v`; no automated security scan ran.

#### Historical partial off-screen appearance review

The normal full suite generated **26 PNG attachments: 20 light/dark pane renders and six expanded
configuration panes**. Representative inspection covered General light/dark, Items light, Behavior
dark, Advanced normal/expanded, Style expanded, About dark, Presets light/dark, Triggers dark, and
Groups light. Form contents were readable; expanded Advanced controls and error text fit close to
the bottom.

`cacheDisplay` omits glass/sidebar text and icons and some native material-backed content, leaving
blank portions in Items and Advanced-child cards. AX geometry and real-control checks passed across
all panes, including those omitted regions. This is a partial appearance review, not full-window
visual verification. Live sidebar/material appearance, non-collapsibility under drag, pointer/keyboard
focus, child/back navigation feel, VoiceOver, and browser handoff remain outstanding.

The About PNG displays the test runner's `Bundle.main` version, **16.0**, rather than the production
app's version. A temporary layer-render experiment did not improve the omissions and was reverted.
At the end of that pass, the production/test sources matched its passing full-suite run. The current
drag/search/chrome changes have their own 2026-09-16 verification record above. Test artifacts for the
prior baseline were transient; retention of its result bundle or exported PNGs is not guaranteed.

### Parity Verification

Historical full build/test on 2026-09-13: 1132 tests across 80 suites, 1760 invocations, zero failures or skips.
The built app passed strict code-signature verification. Each wave had an independent read-only review
whose concrete findings were fixed before commit (background trigger applies deferring like launch
placement; spacing written only on explicit change; Live-mode busy gate including a revealed section;
failure backoff; stray always-hidden items mirrored as hidden; make-room restore on every collapse
path including quit).

| Coverage | Evidence | Level |
|---|---|---|
| Presets, triggers, groups, widgets, spacing, style, hotkeys, notch planner, draft models | `LayoutPresetTests`, `TriggerEvaluatorTests`, `ItemGroupTests`, `MenuBarWidgetTests`, `MenuBarSpacingTests`, `MenuBarStyle*Tests`, `HotkeyAssignmentsTests`, `NotchOverflowPlannerTests`, `ItemControlStoreTests` (tri-state) | Unit |
| Monitors and controllers with injected sources, clocks, factories, registrars, defaults, runners | `TriggerMonitorTests`, `ScrollRevealMonitorTests`, `GroupStatusItemsControllerTests`, `WidgetStatusItemsControllerTests`, `MenuBarSpacingServiceTests`, `MenuBarStyleOverlayControllerTests`, `HotkeyServiceTests`, `NotchOverflowCoordinatorTests`, `RestartServiceTests`, `UpdateCheckServiceTests` | Adapter |
| Engine wiring: lazy tier divider, option-click, notch make-room and restore ordering, quit restore | `CosmeticHideEngineTests`, `NotchOverflowEngineTests`, `PlacementIntegrationTests`, `StagedPlacementIntegrationTests` with `FakeWindowServer` | Hostless integration |
| Every Settings pane and section, sidebar navigation, onboarding steps, real presses and field edits | `*SettingsTabTests`, `*SettingsSectionTests`, `SettingsSidebarTests`, `SettingsViewTests`, `OnboardingTests` | Hostless rendering + interaction |

No native probe was run for a feature in that parity wave. The current "Needs hardware verification"
list in AGENTS.md applies to retained behavior; widget-specific paths and QA were later retired.

### Icon Reliability Verification

On 2026-09-15 the user reported frequent app-icon fallbacks and the screen-recording indicator
appearing in both the bar and the mirror. Every capture since 09-14 13:40 had returned an opaque
black menu-bar strip while the rest of the display captured normally (`BKF_DUMP_CROPS` now writes
the full frame with per-band luma: strip 0, rest 43). The menu bar was hidden by a fullscreen Space;
`kCGWindowIsOnscreen` was false for every status window, including the Clock. Three launches that
day happened in that Space, each caching six fallbacks, and cache-only opens never replaced them.
The indicator is permanent on this machine because DisplayLink Manager records the screen.

Fixes, in order: snapshots carry `isOnScreen`; a pass whose anchor is on its display but off screen
refreshes membership without revealing or asking ScreenCaptureKit; leaving a Space and closing the
bar each run one debounced check that refreshes only an incomplete or out-of-date mirror; opening
prunes the mirror to what is tucked now; Control Center modules that Accessibility resolves are not
mirrored while unresolved items stay reachable; captured glyphs are remembered per attribution label
under Caches and stand in until this launch captures its own.

Historical full build/test after Live mode removal: 1108 tests across 81 suites, 1812 invocations,
zero failures or skips. Strict code signature verification passed for that build.

| Coverage | Evidence | Level |
|---|---|---|
| Hidden menu bar at launch: zero captures, no reveal, fallbacks reachable; a Space change while still hidden does nothing; the first visible Space change captures once (reveal, capture, collapse); a complete cache asks nothing | `MirrorReliabilityWorkflowTests` with the real engine and controller over `FakeWindowServer` | Functional workflow |
| Closing an incomplete bar refreshes once after the debounce; reopening first cancels it; a complete, current mirror never refreshes; an item moved back beside the anchor leaves the mirror on the next open without capture | `MirrorReliabilityWorkflowTests` | Functional workflow |
| Resolved Control Center module excluded from mirror and Settings; unresolved blanket-label item kept | `MirrorReliabilityWorkflowTests` | Functional workflow |
| Relaunch with new window ids and a hidden bar shows remembered glyphs, not app icons; a damaged file falls back; a newcomer falls back; this launch's capture replaces every remembered glyph and rewrites the damaged file | `MirrorReliabilityWorkflowTests` with `GlyphStore` in a temporary directory | Functional workflow |

Live verification so far: the relaunched app logged `capture: menu bar hidden; skipping reveal` on
its warm-up while the user's fullscreen Space was active and made no ScreenCaptureKit request. The
visible-bar half (`isOnScreen == true`, real glyphs after leaving the Space) is confirmed only by the
window-list semantics Ice relies on and still needs a session on a normal Space. A rapid relaunch
also resolved the previous instance's lingering control windows once and left placement pending;
it recovers on the next resume and is not part of this fix.

### Settings Split And Icon Verification

On 2026-09-14 the user reported that General scrolled and asked for a choice of BKF icons. General
was measured at ten sections; Behavior with the moved sections still overflowed by 300 to 550pt, and
Style with spacing reached 1041pt in a 704pt detail area. That historical arrangement kept every pane's
bottommost control inside the window: General (login, permissions, spacing, backup), Behavior
(floating bar, re-hide, hover, scroll), Placement (layout mode, notch), Shortcuts, and Style
(icons, styling, preview). Placement refreshed the permission probe itself, so its Accessibility
warnings could not go stale when General was never visited. The current hierarchy is documented
above; spacing/backup/notch now live in Advanced and Placement was removed with Live mode.

Icons are a new `Preferences.appIcon` value decoded field by field. The menu-bar symbol is applied
to the anchor only when it changes; the app theme reaches the Settings header, the About panel, and
`NSApp.applicationIconImage` for alerts. The signed bundle is never modified, so the Finder icon
stays as shipped and granted permissions survive. Ocean, the shipped artwork, never falls back to
`NSApp.applicationIconImage`, which this feature itself sets.

Historical full build/test: 1168 tests across 84 suites, 1886 invocations, zero failures or skips. Strict code
signature verification passed. Two independent review passes found and closed: an Ocean fallback that
would have echoed the active theme, stale Placement permission warnings, a Dock claim for an app with
no Dock tile, search-term fusion, a tooltip on the wrong control, and duplicate VoiceOver labels.

| Coverage | Evidence | Level |
|---|---|---|
| Choose both icons in the real Settings UI; one write per edit, one anchor image, zero placement/capture work; unapplied Items draft and aliases intact; fresh store/model/engine reload the choice and no draft; re-selecting the current value writes nothing; leaving Ocean and returning restores it | `AppIconWorkflowTests` with real `PreferencesStore` in an isolated `UserDefaults` suite and the real engine | Functional workflow |
| Export/import round trip; per-field leniency (unknown symbol keeps a valid theme); both-bad, string, and integer `appIcon` values; missing key on older files | `AppIconWorkflowTests` | Functional workflow |
| Every symbol renders a visible template glyph; every theme renders the shared mark on transparent margins and differs from Ocean | `AppIconWorkflowTests`, bitmap rendering | Rendering |
| Configuration panes' bottommost controls visible in the historical 820x720 arrangement in their richest permission-independent states | `SettingsSidebarTests.bottommostControlIsVisibleWithoutScrolling` | Hostless rendering |
| Search keywords follow the moved sections; moved terms no longer match General | `SettingsSidebarTests`, `SettingsSearchTests` | Unit + hostless interaction |

`install()` does not run in hostless tests, so the install-time anchor image and the live status
button are exercised only through the `setAnchorImage` seam. The pop-up's native menu items are not
reachable off screen; the workflow drives the exact binding the picker holds. Live appearance of the
chosen symbol in the menu bar and the About panel's rendering remain hardware QA.

### Settings Search Highlight Verification

On 2026-09-15 the user requested a highlight at the destination of a Settings search. The sidebar
preserves the selected query when it clears the search field, so `SettingsView` can identify the
matching settings or sections. The cue lasts three seconds, also works for the current
page, and resets on repeated selection. Typing another query or navigating elsewhere clears it;
an older timeout cannot clear a newer cue.

An unavailable control highlights its enabling switch. For example, searching "opacity" with styling
off highlights "Style the menu bar"; explicitly enabling styling transfers the cue to the opacity row.
A query such as "Style opacity border" highlights both matching rows. A page-name-only query
highlights the page heading. Search does not enable features, open editors, or move keyboard focus.

The outline and background tint occupy no additional layout space and ignore pointer input. Reduce
Motion suppresses the fade. Accessibility custom content marks the region as "Settings search: Match"
while retaining existing control values and help text. Plain accessibility hints did not surface on
SwiftUI container groups in the workflow tests; custom content does.

| Coverage | Evidence | Level |
|---|---|---|
| 34 queries across every pane, Return and result-button activation, shared sections, page qualifiers, accents, matching destination bounds, and retained Items drafts | `SettingsSearchTests.searchResultsHighlightTheirDestinationsAcrossEveryPaneWithoutApplyingAnything` | Functional workflow |
| Hidden controls point to visible switches; disabled hover stays disabled; explicitly enabling styling transfers the highlight and saves once | `SettingsSearchTests.hiddenAndDisabledSearchControlsPointToReachableDestinations` | Functional workflow |
| Current-page repeat, independent expiry, manual/external navigation, new and unmatched queries, no Items reload or draft loss | `SettingsSearchTests.repeatedHighlightsExpireIndependentlyAndNavigationClearsThemWithoutLosingDrafts`, existing search interaction tests | Functional workflow |
| Actual highlight pixels and stable bounds in light/dark with motion enabled/disabled; highlighted checkbox activation persists one edit | `SettingsSearchTests.highlightsPaintTheDestinationWithoutResizingOrDisablingIt` | Hostless rendering + interaction |

The search harness uses the real model, an isolated `UserDefaults`-backed `PreferencesStore`, and the
real engine. Item reads and native capture/status-button operations are counted at the existing seams.
Search emits no new logs or metrics; tests assert zero writes, moves, and capture before an explicit
setting edit. No native input events are posted and test windows remain off screen. On-screen VoiceOver
delivery and animation feel remain native QA; auto-scrolling to a control is outside this change.

**Historical last full-suite result before Settings simplification/widget retirement:**
macOS 26.6.2 with Xcode 27.0, 1112 tests across 81 suites, 1819 invocations, zero failures or skips.
That signed app passed `codesign --verify --deep --strict`. `scan_diff` was unavailable; that diff
received manual security review. These results do not verify the current changes.

### Settings Search Verification

On 2026-09-14 the user requested search within Settings and Style directly below Items. A native
`NSSearchField` sits below the sidebar identity. It filters pages by their names and static setting
keywords, including controls hidden behind disabled options. All query words must match; matching
ignores case/accents and ranks page-name matches first. It does not filter individual menu-bar item
names or scroll directly to a control. The historical sidebar order in this change was General,
Items, Style, Presets, Triggers, Groups, Widgets; subsequent splits and widget retirement supersede it.

Typing does not navigate or remount the current pane. Activating a result or pressing Return selects
a page and clears the query; Return with blank text or no match does nothing. Escape, the native clear
button, and external tab requests also clear it. Return/Escape defer to the input method during marked
text composition. Search history is disabled, and query state is session-only.

Historical full build/test: 1161 tests across 82 suites, 1847 invocations, zero failures or skips. Strict code
signature verification passed. Independent review found no remaining issues after fixing activation
of an already-selected result and adding input-method/event-ordering coverage.

| Coverage | Evidence | Level |
|---|---|---|
| Sidebar order/identifiers, page-name ranking, keywords, empty/no matches, case/accents/whitespace, trigger/widget action labels | `SettingsSidebarTests` | Unit |
| Native field bounds and full-pane fit in light/dark; rendered Style-after-Items order | `SettingsSearchTests`, existing `SettingsSidebarTests` layout assertions | Hostless rendering |
| Field-editor typing, native List selection, result activation, Return, clear/Escape, external tab requests, marked text and immediate submission | `SettingsSearchTests` | Hostless interaction |
| Mounted Items, cached rows/images, mixed placement draft, unchanged preference-write/retry/item-provider counts while typing | `SettingsSearchTests` | Hostless integration |

That change added 16 tests / 58 cases. No placement, capture, attribution, global shortcut, persistence key,
telemetry, or background search work was added. Explicit page selection retains that page's existing
lifecycle reads. Test windows never order on screen or post input. Live pointer feel, VoiceOver, and
real input-method handoff remain native QA, not claims established by off-screen tests.
Automated security scanners were unavailable; the diff received manual security review.

### Apply Reliability Verification

On 2026-09-13 the user narrowed work to repeated Items Apply failures. Current logs identified Alfred
as the failed item in two mixed batches, with successful relay forwarding but no relocation. During
supervised testing with BKF paused, three immediate-drop attempts failed and three attempts waiting
for observed grab movement succeeded. The item entered drag state after the relay echo; one successful
drop then needed about 500ms for the divider to reach its final position.

The mover now waits up to 250ms for grab movement, preserving a balancing up across timeout, read
failure, or cancellation. After the initial 120ms settle it polls live item/control geometry for up
to one second before retrying. A frame still outside the menu-bar row cannot count as success or
receive a recovery click. The five-attempt limit and event-routing fields are unchanged.

Historical full build/test: 1145 tests across 81 suites, 1789 invocations, zero failures or skips. Strict code
signature verification passed. An independent review found a delayed-release validation gap; the
on-row guard and its regression tests addressed it before native verification.

| Coverage | Evidence | Level |
|---|---|---|
| Delayed grab, 500ms control animation, Hidden/Shown, negative origins, refreshed retry geometry | `NativeMoveTests` invokes the real `SystemWindowServer.move` with scripted dependencies | Adapter |
| Delayed/off-row release, bounded failure, observation errors, cancellation during grab and settling, balanced cursor cleanup | `NativeMoveTests`, `ScrombleRelayTests`, `CursorConcealmentTests` | Adapter |
| Staging, one saved write, sequential mixed moves, partial failure and Retry | Existing `StagedPlacementIntegrationTests` and `HiddenItemControllerTests` remain green | Hostless integration |
| Six batches, including four mixed-direction batches; ten moves, each on attempt one | Production controller/mover, native events, independently confirmed Alfred/ACME owners; fresh window-list verification after each batch; original frames restored | Native, built-in display |
| Saved Alfred Hidden request after standalone restart | Production AX attribution and placement: one planned move, one success, zero failures; collapsed-state observation confirmed Alfred hidden and ACME shown | Native, built-in display |

The new suite adds 13 tests / 29 cases; the initial 19 failing cases reproduced defects before the
behavioral fix. Automated tests replace every native-effect hook and never post input. Existing
diagnostics add `grabbed` and geometry `ready` outcomes; tests assert behavior rather than log strings.
No capture or AX-attribution pass, idle timer, telemetry, persistence key, or permission was added.
`scan_diff`, `gitleaks`, and `semgrep` were unavailable; the diff received manual security review.

These results do not qualify every third-party item, external displays, visual cursor flicker, or
native lock transitions. Polling deadlines cannot interrupt a non-returning synchronous native read.
The remaining Settings attribution/capture costs are separate from this move-sequencing fix.

### Settings Verification

Historical full build/test on 2026-09-12: 510 tests across 42 suites, 833 invocations, zero failures or skips.
The built app passed strict code-signature verification. Independent reviews found no remaining
issues after fixes for stale-observation retries, deferred-intent reversal, complete draft previews,
and alias loss during row regrouping.

| Coverage | Evidence | Level |
|---|---|---|
| Owner-keyed drafts, reversal without manufacturing intent, mixed/unknown siblings, merge preservation | `ItemPlacementDraftTests` | Unit |
| Apply once, identical-intent retry, in-progress guards, import replacement, concurrent reloads, preview order/aliases | `SettingsModelTests` | Adapter |
| Zero native work while drafting/discarding/previewing; one shared placement cycle and successful capture after Apply | `StagedPlacementIntegrationTests` with counted native dependencies | Hostless integration |
| Partial failure, unresolved-only retry, stale/overlapping Shown observations, paused request replacement | `StagedPlacementIntegrationTests`, `PlacementIntegrationTests` | Hostless integration |
| Actual Apply/Discard/bulk actions, retained cached rows, unknown choices, mounted alias edits across regrouping | `SettingsViewTests` | Hostless rendering + interaction |
| Cached pixels, accessible non-button labels, horizontal/vertical overflow, full 640x720 window fit with errors | `SettingsPlacementPreviewTests`, `SettingsViewTests` | Hostless rendering |

Draft edits and previews add no polling, capture, telemetry, or permission requirement. Existing
placement/capture diagnostics remain in use; tests assert work counts rather than log strings.
`scan_diff`, `gitleaks`, and `semgrep` were unavailable; the production diff received manual security
review, not an automated scan pass.

The previews are schematics of manageable items. They use cached glyphs or app icons, keep unknown
placement separate, and do not promise exact native spacing/order or fresh images. Unapplied drafts
survive closing Settings only within the running session. Apply persists desired placement before
native verification, so failures remain visible and retryable rather than rolling back saved intent.
Batching removes repeated outer cycles; native settling/retries and separate post-move attribution
passes remain. No native end-to-end speed measurement or external-display fix is claimed.

Test windows never order on screen or post input. They enable and restore process-local accessibility
metadata for in-process control testing. On-screen focus and VoiceOver navigation still need human QA.

### Hover Verification

Historical full build/test on 2026-09-11: 456 tests across 38 suites, 706 invocations, zero failures or skips.
The built app passed strict code-signature verification. Independent source review found no
remaining issues after fixes for context-menu ownership, synthetic pointer excursions, focus-taking
presentation calls, and held-click races.

| Coverage | Evidence | Level |
|---|---|---|
| Dwell, exit grace, anchor/panel/gap transit, invalid and negative-origin geometry | `HoverRevealStateMachineTests` | Unit |
| Manual ownership, queued/suspended cancellation, stale callbacks, mouse-button gating, teardown | `HoverRevealControllerTests` with fake clocks and gates | Unit |
| Pause, preference/mode disable, uninstall, shortcut/context-menu cleanup, activation handoff | `HoverRevealIntegrationTests` using the real engine and bar state | Hostless integration |
| Manual-close suppression during placement-owned pointer excursions | Real engine and mover with `FakeWindowServer` and gated attribution | Hostless integration |
| Hover stays non-key through re-layout; fresh click/keyboard opens may become key | Actual `present()` path with intercepted NSPanel ordering calls | Hostless integration |
| Default off, legacy decoding, save/reload, layout round-trip, unrelated settings unchanged | `PreferencesTests`, `LayoutConfigTests`, `PlacementIntegrationTests` | Unit + hostless integration |
| Row/cell hover pixels, stronger press feedback, no disabled highlight, stable light/dark sizing | `FloatingBarViewTests` drawing production button content through `NSHostingController` | Hostless rendering |
| Actual cached opens with fresh/stale/empty/failed enumeration; skipped successors restore; warm-up cancellation preserves display refresh | `HoverRevealIntegrationTests`, `CosmeticHideEngineTests` with physical-divider spies and intercepted panels | Hostless integration |
| Cursor capability fallback, own connection, missing position, cleanup failure/cancellation, session loss | `CursorConcealmentTests` with injected primitives and pure session data | Unit + adapter |
| Delayed trigger/echo, timeout fallback, no duplicate down, balancing up after interruption | `ScrombleRelayTests` through production relay-state and move-pair methods | Adapter |
| Terminal AX interruption, no later fallback, enabled items after interruption, current reveal released without touching successors | `AXActivatorTests`, `FloatingBarControllerTests`, `PlacementIntegrationTests` | Unit + hostless integration |

Native focus/first-click delivery, animation feel, and multi-display behavior are deliberately not
claimed as verified. Test panels never order onto the desktop, and tests do not post mouse events
or capture the screen. The actual `show()`/capture re-layout call sites were source-reviewed.
Item-highlight tests seed interaction state rather than delivering native pointer events. They
use AppKit hosting because `ImageRenderer` added a disabled-state artifact even without a background.

Diagnostics reuse local `DebugLog` messages for monitoring enabled/disabled, manual relinquishment,
presentation visibility, and hover-owned closure. There is no telemetry or per-poll logging;
tests assert behavior, not log strings. No automated security scan was available (`scan_diff`,
`gitleaks`, and `semgrep` were absent); the diff received manual security review.
Item-level hover feedback adds no polling, logging, telemetry, or permission requirements.

### Native Investigation

- **Cached opening:** a standalone diagnostic toggle displayed the panel while all 40 samples
  retained the 1728pt divider. This verifies that opening did not initiate a real-item reveal on
  that run, not that background startup capture or explicit item activation never reveals items.
- **Cursor capability:** on an unlocked desktop with another app frontmost, the ordinary hide call
  returned success without hiding. Setting the calling process's `SetsCursorInBackground` property
  produced visibility 1 -> 0 -> 1 with balanced hide/show. A controlled click compiled from the
  production bridge opened Itsycal and restored within one point, stable after 350ms. Those endpoints
  are not a complete visual-flicker recording; unsupported capability/hide failures remain best-effort.
- **Itsycal placement:** the external setup exposed separate original and compositor windows, with
  the original/AX geometry above the visible row. No replacement routing was shipped on that hypothesis.
  The external displays became unavailable. Built-in Shown placement and successful menu opening do
  not close the external-display bug.
- **Capture:** unlocked built-in-display probes of the status windows returned transparent images
  through both ScreenCaptureKit's independent-window API and `SLSHWCaptureWindowList`. No new capture
  transport was shipped. Fresh glyph acquisition still uses the composited display; cached opening
  does not need it. Icon freshness remains event-driven, and fallback recovery remains open.

Apple documents ordinary off-screen independent-window capture in
[WWDC22 session 10155](https://developer.apple.com/videos/play/wwdc2022/10155/), but that is not proof
that Tahoe status-item surfaces contain usable glyphs. The private connection-property ABI is
documented in [CGSInternal](https://github.com/NUIKit/CGSInternal/blob/master/CGSConnection.h);
only the API mechanism was used, not third-party implementation code.
[Bartender's support page](https://www.macbartender.com/Bartender6/support/) also says it moves the
mouse for layout management and that On-Demand avoids unsolicited moves. Its closed-source capture
implementation is not established by those public claims.
