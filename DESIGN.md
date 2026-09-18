# DESIGN.md

Design direction for Hisingen. Transcribed on 2026-09-18 from the shipped app
(`Sources/Hisingen/UI`), not invented: every field below is how the app already looks and
behaves, with the source file named. Nico owns this file; correct anything that reads wrong.
Where this file and the code disagree, the code wins and this file gets fixed. Tokens live in
`Sources/Hisingen/UI/Theme/` and `Sources/Hisingen/UI/Motion.swift`.

Reading this as: a macOS menu-bar utility panel for Volvo and Polestar EV owners, in a
Scandinavian instrument-panel language, dial ENERGY 2 / RHYTHM 2 / MOTION 2.

Hisingen (the Gothenburg island where Volvo builds cars) is a compact popover of cards:
battery, climate, charging, tyres, trips, service, with remote controls. Quiet, precise,
warm where things act.

The instrument layer (added 2026-09-18, same language): the hero render carries a living
overlay drawn only from real vehicle signals (`LivingVehicleView`) — an open door or hood
places a warning-tinted marker at its body position, an active climate session breathes
accent warmth from the vent line, a charging session runs the gauge's particle rail beneath
the body; with no signals it draws nothing, because a healthy car does not glow. Commands
report their flight from the control itself via the shared `sendingOverlay` capsule.
Pull-to-refresh (rubber-band physics, commits on release velocity), one-step momentum
tab swipes, and hover-handle card drag-reorder make the panel directly manipulable; the
flick spring (`Motion.flick`, the one sub-1.0 damping) is reserved for what a gesture
threw. The panel materializes on arrival on the shared entrance curve. A charging session
renders as the hero's scene (`ChargingSessionScene`): the car's own finish estimate leads
at the display tier, arriving power supports it, and no figure is ever shown that the car
did not report — projections derive capacity from readings only when they must, and say
so (`ChargeTargetProjection`, `InstrumentMath`).

## Dials

- **ENERGY 2** (Stripe, not GOV.UK): one composed entrance, one accent, data first. A utility
  that must never shout; the readings are the display, not the chrome.
- **RHYTHM 2**: one card grammar everywhere, deliberately broken by the vehicle hero, the
  charts, and full-width banners.
- **MOTION 2**: every state change animates, nothing bounces. Ambient motion only where the
  car is actually doing something, and only while anyone can see it. Gesture-carried motion
  (pull, swipe, reorder) may settle with the flick spring's one step of overshoot, because
  the gesture itself carried the velocity; state changes stay critically damped.

## Personality

Measured craft, and the discipline is the identity: every token in the theme files carries
its reason in a doc comment, contrast is enforced by a build-failing script
(`Scripts/verify-app-contrast.py`), and every question has one answer, one token, one written
reason. Geometry, type and shadows are global; themes vary colour only, because a theme is a
palette choice, not a layout choice.

## Palette

Neutrals carry structure, one accent carries action, semantics carry state. That is the whole
active palette per theme: neutrals plus one accent, by construction.

- Structure: `canvas`, `cardFill` (the canvas lifted toward white: 55% light, 16% dark),
  `chipFill` (the card sunk toward black), `ink`, `inkMuted`, `hairline`. Every token is a
  dual-appearance pair; light and dark are both first-class, never an afterthought.
- Accent: one per theme, spent on acting elements and live values only. Tinted fills that
  carry accent-coloured text hold at or below 12% opacity (hover 8%), the ceiling the
  accent's 4.5:1 guarantee covers.
- Status: `semanticGood/Active/Warning/Critical/Fault/Fuel` keep their system hue and move
  lightness to hold 4.5:1 on every theme's card and on a 12% wash of themselves. A hardware
  fault is never the same colour as a low tyre ("add air" and "book service" must not match).
- Charts: series are data with their own tokens (`chartPositive/Info/Attention/Health`),
  checked 3:1 against the card and against each other where they share axes. Decorative tint
  is for header glyphs only, never for plotted data.

The nine themes:

| Theme | Accent | Character |
|---|---|---|
| Hisingen Glass (default) | `#E56E23` amber | Rounded cards, translucent materials, amber accents |
| Monochrome Precision | `#E56E23` | Polestar monochrome, high-contrast type |
| Heritage Blue | `#005B94` | Volvo blue, calm surfaces |
| Nordic Night | `#00E5FF` | Pitch OLED black, electric cyan |
| Aurora Borealis | `#00E676` | Midnight slate, northern-light emerald |
| Swedish Gold | `#D4AF37` | Dark charcoal luxury, BST gold |
| Cyan Racing | `#0090D0` | Championship blue, track geometry |
| Gothenburg Forest | `#4CAF50` | Swedish pine, organic soft |
| Sand Dune | `#C5A059` | Desert sand, titanium champagne |

Gradient use is structural, not decorative: the app's only gradient is the specular rim on
glass cards. Brand warmth lives in the accent token, never as a wash over large surfaces.

## Typography

SF Pro, the platform face; a menu-bar utility does not import a brand font. Applied through
one ramp (`HisingenTheme+Typography.swift`):

- Tiers: nano 8, micro 9, caption 10, label 11, body 12, heading 13, subhead 14, title 15,
  displaySmall 17, display 28, displayLarge 44. The two display tiers are the instrument's
  focal figures: one displayLarge figure per screen (the hero's battery level), a display
  headline for the charging scene's finish estimate. Every tier scales with the reader's
  text size (`@ScaledMetric`) and the density preset; no frozen point sizes at call sites.
  Set tiers via `hisType(_:weight:design:)`.
- Weight ladder frozen: headings semibold, values bold, captions semibold. Below 10pt, weight
  goes up, not down.
- Optical tracking: positive below 12pt (+0.04 per point), negative for display (-1.1% of
  size), so tracking follows the rendered size.
- Telemetry values roll with `.numericText()` plus `.monospacedDigit()` plus the telemetry
  token (`hisTelemetryValue`); tabular figures are part of the contract.
- Wrapped small text gets +2pt leading (`hisCaptionLeading`), because Swedish and German
  ascenders run taller than English at the same point size.
- No monospace headings, no uppercase labels with wide tracking.

## Surfaces and geometry

One radius per question, all global (`HisingenTheme.swift`): cards 12, banners 10 (a
concentric inset of the card), gauges 5, status chips 4. Nothing is pill-shaped by default.

Material discipline, the app's strongest identity rule: exactly one translucent surface in
any stack. Panel = `.regularMaterial` glass; card = solid `cardFill`; chip = solid
`chipFill`. Blurs never stack. Under Reduce Transparency or Increase Contrast the panel goes
opaque and darker than any canvas, so the lifted card still separates.

Elevation is a three-step ladder chosen by surface size, not theme: onCard (chip) < card <
floating panel. One shadow per surface, black in light and a lifted white in dark.
Separation comes from the boundary stroke (1pt hairline; a 3:1 boundary under Increase
Contrast) and the shadow, never from stacked translucency. Card padding 15 and section
spacing 12, both density-scaled; whitespace is structural.

## Motion

Tokens grouped by why (`Motion.swift`):

- **Interaction**: fast, easeOut, no overshoot (0.2s; 0.11s for micro acknowledgements).
  Buttons press with scale 0.97 plus a slight dim, minimum 24pt target.
- **State**: critically damped springs, damping 1.0. Nothing rings. Overshoot is reserved for
  gestures that carry momentum, and the app has no drag gestures.
- **Ambient**: breath 3.4s, live pulse 1.6s, spin 1.4s, tiny deltas (opacity 0.6 to 1.0,
  scale 1.0 to 1.04), gated by panel visibility (`ambientMotionAllowed`), frugal frame counts
  in the menu bar.
- **Entrances** share one curve (0.16, 0.72, 0.20, 1.0) across SwiftUI, AppKit and the
  vehicle roll-in, so every entrance reads as one system.
- **Reduce Motion** resolves in one place: nil, or a 0.11s crossfade so a change is still
  noticed. Keyboard focus is an ink underline (12x2), deliberately not accent-coloured.

## Components and states

- Cards are the universal grammar; one definition (`cardSurface`) serves every card.
- Status labels are one family (`Pill`, `StateSummaryChip`, `CommandReceiptChip`) at radius 4.
- Empty states use `HisingenEmptyState` (ContentUnavailableView) with domain-specific copy
  and real recovery actions; loading and error states are part of every data card.
- SF Symbols, hierarchical rendering, domain-relevant glyphs (a fan for climate, a battery
  for energy). If no genuinely relevant symbol exists, use none.

## Voice

Instrument-panel English: terse, numeric, specific. "12 V battery low", "%d min remaining",
"111.0 kWh Extended Range (CATL · 64.0 kWh Usable · 400V)". No marketing adjectives, no
buzzwords, no em dashes in UI copy (verified zero in the 2,557-line English strings file).
Claims come from the car, never from copy. Localized in 16 languages; layouts tolerate
length, because Swedish and German run longer than English.

## Focal point and accent

- One focal point per screen: the hero reading (battery and range on the vehicle hero, the
  active chart in history); everything else defers to it.
- The accent is the one deliberate accent. Ink, not accent, marks focus; inkMuted, not
  accent, marks muted text; semantics, not accent, mark state. If everything is amber,
  nothing is.
- Identity motif: cool Nordic neutrals with one warm accent, Swedish heritage naming, and
  the vehicle silhouette as the recurring hero gesture.
