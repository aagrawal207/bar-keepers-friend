# Bartender Parity

Last reviewed: 2026-09-12. Reference: [Bartender 6 product](https://www.macbartender.com/),
[release notes](https://www.macbartender.com/Bartender6/release_notes/), and
[support](https://www.macbartender.com/Bartender6/support/).

Full parity is not established. The checklist separates shipped behavior, automated verification,
and native behavior that still needs evidence. Passing geometry or fake-backed tests does not prove
that macOS opened a particular third-party menu or rendered a cursor without flicker.

## Core Workflows

| Capability | Current State | Remaining Work |
|---|---|---|
| Permission-free hide/show | Implemented using BKF's own divider | Preserve this baseline through every change |
| Per-item Shown/Hidden | Live verified for Maccy and ACME; observed placement and retry feedback implemented | Itsycal failed on a 1920-point external display, then succeeded on the built-in display; external behavior remains open |
| Floating bar under a crowded menu bar | Cached icons, horizontal/vertical wrapping, off-screen hosting tests | External-display restart yielded 0/9 glyphs with app-icon fallbacks; recovery, cold-boot collection, saturated-notch activation, and capacity beyond both grid axes remain unverified |
| Item pointer feedback | Shared row/cell hover and pressed highlight; light/dark, disabled, and sizing checks use off-screen AppKit drawing | Native enter/exit across label/whitespace and reacquisition after host replacement |
| Item activation | Positioned click with own-connection background concealment; interruption-safe optional AX path | Universal no-flicker behavior, menu compatibility, and external-display qualification |
| Hover reveal | Cache-only opens; optional captures revalidate after queue waits; ownership and non-key ordering tested | Native first-click delivery, focus, animation transit, display qualification, and freshness without intrusive capture |
| Keyboard access | Configured global toggle and persistent keyboard-opened bar | Shortcut recorder/conflict feedback and accessible navigation/dismissal |
| Display correctness | Placement re-reads controls; several coordinate fixes are tested | Explicit 2D display identity, negative-origin capture, stacked-display panel selection, and live external-display qualification |
| Native-work resilience | Pause/superseding/session interruption cancel safely; submitted downs retain balancing ups; interrupted placement stays pending | Native lock-transition qualification, Space/fullscreen/mouse-idle policies, and genuine recovery from non-returning calls |

## Organization And Distribution

| Capability | Current State | Remaining Work |
|---|---|---|
| Ordering | Mirror order persists in the existing store, without editing UI | Mirror ordering controls and separately verified native ordering |
| Multiple items from one owner | Coupled by the existing persisted owner key | A deliberate migration design before any independent identity scheme |
| Presets/profiles | One layout can be exported/imported | Named arrangements before automatic triggers |
| Triggers | Not implemented | Battery, Wi-Fi, app/schedule conditions after presets are stable |
| Groups/Always Hidden | Not implemented as usable workflows | Tested models and native qualification without weakening protected-item guards |
| Settings/onboarding | Staged Apply/Discard placement, cached Menu Bar and Hidden Bar/List previews, live permission status | Native focus/VoiceOver QA, export errors, login approval, and first-run guidance |
| Updates/install | Local Apple Development build | Restart, signed update feed, Developer ID signing, notarization, and installation verification |
| Capture privacy | Whole-display acquisition followed by local icon cropping | Qualify a narrower acquisition path; do not claim menu-bar-only acquisition today |

## Deliberate Differences

- macOS 26 only; no older-macOS compatibility layer.
- Search and visible section dividers remain removed at the user's request.
- Hover was previously removed; its new opt-in implementation follows the user's explicit request.
- Bartender Pro's additional shelf/media/calendar/file utilities are outside the menu-bar-manager
  scope unless requested separately.

## Verification Gates

- Each change needs concrete reachability or a specified capability, regression tests, and an
  independent review proportionate to its risk.
- Native movement must be verified against live item/control frames, not event-post return values.
- Native menu behavior, visible cursor motion, cold boot, and display/Space transitions require
  on-device evidence before being marked complete.
- Never race a new native operation past an unfinished one merely to make a timeout appear fixed.
- Keep persistence keys, attribution-label construction, protected-item exclusions, and the
  permission-free baseline unchanged unless a separately justified migration is required.

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
