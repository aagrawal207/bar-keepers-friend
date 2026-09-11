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
| Floating bar under a crowded menu bar | Cached icons, horizontal/vertical wrapping, off-screen hosting tests | Prove cold-boot collection, saturated-notch activation, and capacity beyond both grid axes |
| Item activation | Positioned click, optional AX path, cancellation/ownership guards | Observe actual menu opening/closing, handle ambiguous AX outcomes, and qualify cursor/focus behavior |
| Hover reveal | Explicitly requested; replacement not yet implemented | Opt-in below Auto Re-hide; preserve anchor-to-panel travel and manual/keyboard ownership |
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
- Hover was previously removed, but the user explicitly requested a new opt-in implementation.
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
