# Bartender Parity

Last reviewed: 2026-09-11. Reference: [Bartender 6 product](https://www.macbartender.com/),
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
| Item activation | Positioned click, optional AX path, cancellation/ownership guards | Observe actual menu opening/closing, handle ambiguous AX outcomes, and qualify cursor/focus behavior |
| Hover reveal | Implemented opt-in below Auto Re-hide; ownership, cancellation, geometry, and non-key ordering calls tested | Native first-click delivery, focus, animation transit, and display qualification |
| Keyboard access | Configured global toggle and persistent keyboard-opened bar | Shortcut recorder/conflict feedback and accessible navigation/dismissal |
| Display correctness | Placement re-reads controls; several coordinate fixes are tested | Explicit 2D display identity, negative-origin capture, stacked-display panel selection, and live external-display qualification |
| Native-work resilience | Pause and superseding work cancel safely; activations join draining moves | Lock/Space/fullscreen/mouse-idle policies and genuine recovery from non-returning native calls |

## Organization And Distribution

| Capability | Current State | Remaining Work |
|---|---|---|
| Ordering | Mirror order persists in the existing store, without editing UI | Mirror ordering controls and separately verified native ordering |
| Multiple items from one owner | Coupled by the existing persisted owner key | A deliberate migration design before any independent identity scheme |
| Presets/profiles | One layout can be exported/imported | Named arrangements before automatic triggers |
| Triggers | Not implemented | Battery, Wi-Fi, app/schedule conditions after presets are stable |
| Groups/Always Hidden | Not implemented as usable workflows | Tested models and native qualification without weakening protected-item guards |
| Settings/onboarding | Settings and live permission status exist | Export errors, login approval, first-run guidance, and visual refinement |
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

## Hover Verification

Full build/test on 2026-09-11: 399 tests across 35 suites, 543 invocations, zero failures or skips.
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
