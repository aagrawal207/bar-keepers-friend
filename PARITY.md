# Bartender Parity

Last reviewed: 2026-09-15 (Settings search destination highlights). Reference: [Bartender 6 product](https://www.macbartender.com/),
[release notes](https://www.macbartender.com/Bartender6/release_notes/), and
[support](https://www.macbartender.com/Bartender6/support/).

Feature-surface parity with Bartender 6 is now implemented for every item on Bartender's public
feature list except Quick Search (removed at the user's request), per-Space/per-display styles, and
signed auto-update. Verified parity is not established: every 2026-09-12/13 feature is hostless-tested
only. The checklist separates shipped behavior, automated verification, and native behavior that still
needs evidence. Passing geometry or fake-backed tests does not prove that macOS opened a particular
third-party menu, moved an item to the requested slot, or rendered a cursor without flicker.

## Core Workflows

| Capability | Current State | Remaining Work |
|---|---|---|
| Permission-free hide/show | Implemented using BKF's own divider | Preserve this baseline through every change |
| Per-item Shown/Hidden | Observed grab/placement polling; six built-in-display Alfred/ACME batches completed ten moves on the first attempt; saved Alfred Hidden also succeeded after restart | Itsycal failed on a 1920-point external display, then succeeded on the built-in display; external behavior remains open |
| Floating bar under a crowded menu bar | Cached icons, horizontal/vertical wrapping, off-screen hosting tests; glyphs remembered across launches; a hidden menu bar (fullscreen Space, auto-hide) is never photographed; the mirror follows current positions on open and refreshes after close or a Space change; Control Center items are never mirrored | The 09-14 fallbacks were a fullscreen Space, not timing. Live confirmation of `isOnScreen` on a visible bar, external-display capture, and cold-boot compositing remain hardware QA |
| Item pointer feedback | Shared row/cell hover and pressed highlight; light/dark, disabled, and sizing checks use off-screen AppKit drawing | Native enter/exit across label/whitespace and reacquisition after host replacement |
| Item activation | Positioned click with own-connection background concealment; interruption-safe optional AX path | Universal no-flicker behavior, menu compatibility, and external-display qualification |
| Hover reveal | Cache-only opens; optional captures revalidate after queue waits; ownership and non-key ordering tested | Native first-click delivery, focus, animation transit, display qualification, and freshness without intrusive capture |
| Keyboard access | Recorder for the toggle shortcut with system-reserved/conflict detection; per-item shortcuts reveal and activate one item (floating-bar mode) | Real Carbon registration of 1+N slots, recorder first-responder behavior, accessible navigation/dismissal |
| Reveal gestures | Click, hotkey, opt-in hover, opt-in scroll/swipe (one effect per gesture, cooldown) | Native scroll-direction feel and monitor routing over the live bar |
| Notch full access | Make-room swap planner + coordinator (default Never): tucks shown items nearest the anchor when a reveal is notch-clipped, restores before every collapse and before quit | Drop relative to a third-party window, partial-overlap tolerance, flicker/latency inside the activation deadline |
| Layout mode | One behavior: saved placement applies at launch, on Apply Changes, and on display change. The Live option (re-apply after app launch/quit) was removed on 2026-09-15 as confusing and hardware-unverified | Whether users miss automatic re-application for apps that relaunch |
| Display correctness | Placement re-reads controls; several coordinate fixes are tested | Explicit 2D display identity, negative-origin capture, stacked-display panel selection, and live external-display qualification |
| Native-work resilience | Pause/superseding/session interruption cancel safely; submitted downs retain balancing ups; interrupted placement stays pending | Native lock-transition qualification, Space/fullscreen/mouse-idle policies, and genuine recovery from non-returning calls |

## Organization And Distribution

| Capability | Current State | Remaining Work |
|---|---|---|
| Ordering | Items rows have Show-in-bar and Move Up/Down controls for the floating bar (presentation-only, immediate) | Native menu-bar ordering is not managed; only Shown/Hidden/Always Hidden placement is |
| Multiple items from one owner | Coupled by the existing persisted owner key | A deliberate migration design before any independent identity scheme |
| Presets/profiles | Named presets (save current, apply, update, rename, delete) in Settings and the anchor menu | Per-display/per-Space presets; native verification of a preset apply is the same as placement |
| Triggers | Battery, charging, battery-below, low power, Wi-Fi, frontmost app, external display, time/weekday rules apply a preset and restore the baseline afterward | IOKit/CoreWLAN callbacks and DST boundaries on hardware |
| Groups/Always Hidden | Groups behind a BKF-owned status item with a member menu; Always Hidden tier behind a lazily created third divider, Option-click reveals it | Slot seeding, tier-divider drops, two expanded dividers, stray-item premise |
| Widgets | Custom status items with allowlisted actions (URL, app, Shortcut, toggle bar); no shell | Live menu-bar appearance, `shortcuts run`, `mailto:` handoff |
| Styling | Tint/gradient/opacity/shape/border/shadow per-display overlay at level 23, excluded from icon capture | Whether the overlay is visible behind Tahoe's transparent bar; fullscreen Spaces; Reduce Transparency interplay |
| Spacing | Global `NSStatusItemSpacing`/`SelectionPadding` override with log-out guidance; explicit changes only | Which global-domain host AppKit reads; effect after relaunching apps |
| Settings/onboarding | Sidebar layout (820x720) with General, Items, Style, Behavior, Shortcuts, Presets, Triggers, Groups, Widgets; Settings search with transient destination highlights; every pane fits without scrolling; staged Apply/Discard, cached previews, live permission status, first-run onboarding for fresh installs, export/login feedback | Glass sidebar rendering, VoiceOver, real `SMAppService` transitions |
| BKF icons | Menu-bar symbol (5 SF Symbols) and app-icon theme (5 gradients on the shipped mark) chosen in Style > Icons; persisted leniently; applied to the anchor, Settings header, About, and alerts without re-signing the bundle | Live anchor appearance and pop-up rendering; the Finder icon is deliberately not changed |
| Updates/install | Manual GitHub release check and Restart in the anchor menu; local Apple Development build | Signed update feed (Sparkle), Developer ID signing, notarization |
| Capture privacy | Whole-display acquisition followed by local icon cropping | Qualify a narrower acquisition path; do not claim menu-bar-only acquisition today |

## Deliberate Differences

- macOS 26 only; no older-macOS compatibility layer.
- Menu-bar search and visible section dividers remain removed. Settings-only navigation search is available.
- Hover was previously removed; its new opt-in implementation follows the user's explicit request.
- Bartender Pro's additional shelf/media/calendar/file utilities are outside the menu-bar-manager
  scope unless requested separately.
- One style and one arrangement for all displays; Bartender styles each menu bar separately.
- Widgets run only allowlisted actions (URL, app launch, Shortcuts, toggle bar); no scripts.

## Verification Gates

- Each change needs concrete reachability or a specified capability, regression tests, and an
  independent review proportionate to its risk.
- Native movement must be verified against live item/control frames, not event-post return values.
- Native menu behavior, visible cursor motion, cold boot, and display/Space transitions require
  on-device evidence before being marked complete.
- Never race a new native operation past an unfinished one merely to make a timeout appear fixed.
- Keep persistence keys, attribution-label construction, protected-item exclusions, and the
  permission-free baseline unchanged unless a separately justified migration is required.

## Parity Verification

Full build/test on 2026-09-13: 1132 tests across 80 suites, 1760 invocations, zero failures or skips.
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

No native probe was run for any parity feature; the "Needs hardware verification" list in AGENTS.md
is the acceptance checklist before any of these is described as working on a real menu bar.

## Icon Reliability Verification

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

Full build/test: 1108 tests across 81 suites, 1812 invocations, zero failures or skips (the Live
mode removal below dropped 64 of the earlier 1171). Strict code signature verification passed.

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

## Settings Split And Icon Verification

On 2026-09-14 the user reported that General scrolled and asked for a choice of BKF icons. General
was measured at ten sections; Behavior with the moved sections still overflowed by 300 to 550pt, and
Style with spacing reached 1041pt in a 704pt detail area. The final arrangement keeps every pane's
bottommost control inside the window: General (login, permissions, spacing, backup), Behavior
(floating bar, re-hide, hover, scroll), Placement (layout mode, notch), Shortcuts, and Style
(icons, styling, preview). Placement refreshes the permission probe itself, so its Accessibility
warnings cannot go stale when General was never visited.

Icons are a new `Preferences.appIcon` value decoded field by field. The menu-bar symbol is applied
to the anchor only when it changes; the app theme reaches the Settings header, the About panel, and
`NSApp.applicationIconImage` for alerts. The signed bundle is never modified, so the Finder icon
stays as shipped and granted permissions survive. Ocean, the shipped artwork, never falls back to
`NSApp.applicationIconImage`, which this feature itself sets.

Full build/test: 1168 tests across 84 suites, 1886 invocations, zero failures or skips. Strict code
signature verification passed. Two independent review passes found and closed: an Ocean fallback that
would have echoed the active theme, stale Placement permission warnings, a Dock claim for an app with
no Dock tile, search-term fusion, a tooltip on the wrong control, and duplicate VoiceOver labels.

| Coverage | Evidence | Level |
|---|---|---|
| Choose both icons in the real Settings UI; one write per edit, one anchor image, zero placement/capture work; unapplied Items draft and aliases intact; fresh store/model/engine reload the choice and no draft; re-selecting the current value writes nothing; leaving Ocean and returning restores it | `AppIconWorkflowTests` with real `PreferencesStore` in an isolated `UserDefaults` suite and the real engine | Functional workflow |
| Export/import round trip; per-field leniency (unknown symbol keeps a valid theme); both-bad, string, and integer `appIcon` values; missing key on older files | `AppIconWorkflowTests` | Functional workflow |
| Every symbol renders a visible template glyph; every theme renders the shared mark on transparent margins and differs from Ocean | `AppIconWorkflowTests`, bitmap rendering | Rendering |
| Every pane's bottommost control visible in the real 820x720 window in its richest permission-independent state; panes other than Items/Shortcuts read no items just to render | `SettingsSidebarTests.bottommostControlIsVisibleWithoutScrolling` | Hostless rendering |
| Search keywords follow the moved sections; moved terms no longer match General | `SettingsSidebarTests`, `SettingsSearchTests` | Unit + hostless interaction |

`install()` does not run in hostless tests, so the install-time anchor image and the live status
button are exercised only through the `setAnchorImage` seam. The pop-up's native menu items are not
reachable off screen; the workflow drives the exact binding the picker holds. Live appearance of the
chosen symbol in the menu bar and the About panel's rendering remain hardware QA.

## Settings Search Highlight Verification

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

Full build/test on macOS 26.6.2 with Xcode 27.0: 1112 tests across 81 suites, 1819 invocations,
zero failures or skips. The signed app passed `codesign --verify --deep --strict`. `scan_diff` was
unavailable; the diff received manual security review.

## Settings Search Verification

On 2026-09-14 the user requested search within Settings and Style directly below Items. A native
`NSSearchField` sits below the sidebar identity. It filters pages by their names and static setting
keywords, including controls hidden behind disabled options. All query words must match; matching
ignores case/accents and ranks page-name matches first. It does not filter individual menu-bar item
names or scroll directly to a control. The normal order is General, Items, Style, Presets, Triggers,
Groups, Widgets; tab identifiers are unchanged.

Typing does not navigate or remount the current pane. Activating a result or pressing Return selects
a page and clears the query; Return with blank text or no match does nothing. Escape, the native clear
button, and external tab requests also clear it. Return/Escape defer to the input method during marked
text composition. Search history is disabled, and query state is session-only.

Full build/test: 1161 tests across 82 suites, 1847 invocations, zero failures or skips. Strict code
signature verification passed. Independent review found no remaining issues after fixing activation
of an already-selected result and adding input-method/event-ordering coverage.

| Coverage | Evidence | Level |
|---|---|---|
| Sidebar order/identifiers, page-name ranking, keywords, empty/no matches, case/accents/whitespace, trigger/widget action labels | `SettingsSidebarTests` | Unit |
| Native field bounds and full-pane fit in light/dark; rendered Style-after-Items order | `SettingsSearchTests`, existing `SettingsSidebarTests` layout assertions | Hostless rendering |
| Field-editor typing, native List selection, result activation, Return, clear/Escape, external tab requests, marked text and immediate submission | `SettingsSearchTests` | Hostless interaction |
| Mounted Items, cached rows/images, mixed placement draft, unchanged preference-write/retry/item-provider counts while typing | `SettingsSearchTests` | Hostless integration |

This adds 16 tests / 58 cases. No placement, capture, attribution, global shortcut, persistence key,
telemetry, or background search work was added. Explicit page selection retains that page's existing
lifecycle reads. Test windows never order on screen or post input. Live pointer feel, VoiceOver, and
real input-method handoff remain native QA, not claims established by off-screen tests.
Automated security scanners were unavailable; the diff received manual security review.

## Apply Reliability Verification

On 2026-09-13 the user narrowed work to repeated Items Apply failures. Current logs identified Alfred
as the failed item in two mixed batches, with successful relay forwarding but no relocation. During
supervised testing with BKF paused, three immediate-drop attempts failed and three attempts waiting
for observed grab movement succeeded. The item entered drag state after the relay echo; one successful
drop then needed about 500ms for the divider to reach its final position.

The mover now waits up to 250ms for grab movement, preserving a balancing up across timeout, read
failure, or cancellation. After the initial 120ms settle it polls live item/control geometry for up
to one second before retrying. A frame still outside the menu-bar row cannot count as success or
receive a recovery click. The five-attempt limit and event-routing fields are unchanged.

Full build/test: 1145 tests across 81 suites, 1789 invocations, zero failures or skips. Strict code
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

## Settings Verification

Full build/test on 2026-09-12: 510 tests across 42 suites, 833 invocations, zero failures or skips.
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

## Hover Verification

Full build/test on 2026-09-11: 456 tests across 38 suites, 706 invocations, zero failures or skips.
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

## Native Investigation

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
