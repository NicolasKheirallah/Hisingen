# Hisingen design

Hisingen is an independent macOS menu bar instrument for connected-car owners. At a desk it answers two questions: what did the car last report, and what can I do about it? Its visual system is one typeface, white and black, square geometry, and specifications read as a figure over its label. This file is the single design reference. It holds the direction, the rules for each view, and how they are checked.

## Design read

- **Product:** a desktop instrument for checking and operating a connected car.
- **Use:** quick checks at a desk, with longer visits for schedules, charging records, and vehicle details. The pointer and keyboard are equal paths.
- **Character:** literal, flat, quiet.
- **Bright spot:** the car, and the battery and range figures under it. Black carries selection and the primary action. Live state (charging, an active control) takes the theme's active colour: its accent, or amber in Monochrome Precision, whose accent is ink.
- **Signature:** the spec grammar. A figure sits above its muted label, rows are divided by hairlines, and a chosen place is marked by a 2pt underline the width of its label.

**Energy 2 / Rhythm 3 / Motion 2.** Contrast comes from scale: one large figure pair per screen and regular type everywhere else. Now, Plan, Log, and Car keep different reading patterns. Motion clarifies selection, live telemetry, and gesture response.

Three principles hold the rest together. Strip away anything that delays reading. Keep the distinction between reported and estimated data. Keep control latency visible. An accent colour alone would produce a theme, and these three decisions are what make the instrument.

## Surfaces and palette

Monochrome Precision is the base palette: `#FFFFFF` and `#000000` canvases, a `#666666` secondary, a 12 % hairline, and a `#EFEFEF` studio fill (`#1A1A1A` in dark) for control cards and notices. Nothing inside the panel rounds, casts a shadow, or uses a gradient. The macOS window owns the corners.

| Palette | Light canvas | Dark canvas | Accent, light | Accent, dark |
|---|---|---|---|---|
| Monochrome Precision | `#FFFFFF` | `#000000` | `#000000` | `#FFFFFF` |
| Hisingen | `#F7F7F7` | `#151515` | `#A3390A` | `#FFAA7A` |

`Palette.activeFill` is the live colour: the charge line while charging, the timeline's charging bands, and every active control card. It is the theme's accent, with `activeOn` (the canvas) for text on it, so live state follows the reader's theme. Monochrome Precision's accent is ink, so it uses a warm amber (`#B5770F` light, `#E8A93A` dark) with black text instead: 3.7:1 and 10:1 as a graphic, 5.6:1 and 10:1 for the text. Other palettes keep their colours and take the same geometry, type, and states. Semantic colours identify safety, warning, and system status, always with a label.

The live colour and the Hisingen accent carry separate values in each appearance to meet contrast. Theme names describe a colour or a place.

A reader can make a theme: a name, an accent, and a light and a dark background. `CustomThemeColors.resolve` keeps the picked backgrounds as backgrounds and moves a colour only as far as it must for text to clear 4.7:1 on the canvas, the card fill and the accent wash, so no pair drops under the floor after the hex is rounded. The editor previews the resolved result in both appearances before the reader saves it. A reader theme is stored as `custom:<id>` and follows the same per-brand and per-vehicle paths as a shipped one; deleting it returns anything that pointed at it to the default palette.

### Reader-made themes

Settings, Appearance ends the theme grid with Create Theme. A theme is a name and three colours: accent, light background, and dark background. `CustomThemeColors` derives everything else and adjusts the picks until every text pair reads: a light background is lifted to at least 0.80 luminance and a dark one sunk to at most 0.03; muted text firms toward ink, and the accent darkens in light and lightens in dark, until each clears 4.7:1 on the canvas, the card, the chip and the accent's own 12 % wash. The editor previews both appearances in the resolved colours and says the colours are adjusted for readability. Themes are stored in `custom_themes_v1`, picked with `AppTheme.custom(id)` (raw value `custom:<id>`), so they ride the same per-vehicle and per-brand storage as shipped themes. Deleting a theme clears every selection that named it. `CustomThemeTests` sweeps 200 hostile combinations.

## Type and copy

One face: Helvetica Neue, which ships with macOS. `HisingenTheme.font` maps the weight ladder onto two cuts. Roman carries displays, values, labels, and headings; Medium appears only for semibold and heavier, or medium below 11pt. Running text tracks at -0.019em, display sizes at -0.036em, and text below 11pt gets a little air back. Monospaced design keeps the system face for the plate and readouts. The shared ramp still scales with the reader's text size and the density preset. Scale, alignment and white space carry the hierarchy, so headings are not repeated in bold.

Hisingen's copy is literal: name the subject and its state, then say what to do. Battery, Estimated Range, Locked, Last known readings. Commands start with the verb and preserve established translations. Unsupported or missing readings stay distinguishable from zero. A labelled estimate remains an estimate.

The voice shifts by view:

- In Now, “Estimated Range” qualifies the number and “Last known readings” qualifies the whole display. “Unlock” is an instruction, while “Locked” is a report.
- In Plan, a time gets the largest type because it answers the question first.
- In Log, dates, units, and an estimate label carry the evidence.
- Car treats identity as specifications with labels and values. The title is the model itself, so the surrounding page needs very little prose.

## Main views

- **Shell:** the Hisingen wordmark in regular display type, text tabs, and a 2pt ink underline under the active tab resting on the header rule. Long tab sets fall back to a scrolling icon strip with full accessibility labels.
- **Now:** model name, then freshness: "Checked" plus one shared reading age when every reading agrees; a reading that differs keeps its own line. The car sits straight on the canvas, grounded by its own render shadow; battery and range read as figures over labels, and the 2pt charge line is ink at rest, gold while charging, muted when historical. The control cards under the car are the reader's choice (Settings → Appearance → Controls on Now): Locks, Climate, and Charging by default, plus Air Cleaning, Windows, Honk & Flash, and Tailgate. A chosen card draws only when its remote feature is on and the car reports the capability; locks, climate, and charging always show their state. They sit in a grid: three across, four as two by two, one column at accessibility sizes. Each is a square card on the studio fill; each card is the control, with the verb and an arrow at the foot (the arrow appears on these cards only). An active card (climate or air cleaning running, the car charging) fills with the theme's `activeFill` and writes in `activeOn`: the accent with canvas-coloured text, the pairing the primary button already passes, or amber with black text in Monochrome Precision. A car already charging on its schedule offers no action, since there is no plain stop command, and an unplugged car offers no Charge Now. The state is always written on the card too.
- **Plan:** the "when" page. It opens with the departure: the car's next reported departure, or a time the reader picks to check (kept in the panel, never sent to the car), in large type with the readiness message under it. A 24-hour hairline ruler follows: charging windows as amber bands (solid while charging), climate timers as ink marks, departure as a tick. Then every timer as a row with Edit or Details, and Add Schedule at the end. Charging follows (one target slider, the current limit with its note in an info button, Charge Now and Resume Schedule), then the planner, then climate settings: temperature and seats, which Now's climate card uses when it starts climate. Start Climate lives on Now. Lock, window and locate, and software install controls live on Car; Plan keeps one only when the reader placed it there or their Car layout does not draw it. The remote-commands footnote closes the tab.
- **Log:** two underlined rows: the period (with Custom… opening the range editor) and the section group (All, Charging, Driving, Climate, Status). The full-history note lives in an info button. One large period figure, the ruled session chart, and month comparisons as figures over labels.
- **Car:** the category filter shares a row with the jump and report menus. Freshness is named only for an offline copy, a stale check, or an old reading; the footer covers the rest. Model and year, the car straight on the canvas as on Now, the VIN and specifications as values over labels. Software install sits after the software section; lock controls and windows, honk and flash after parking location. Reading timestamps come last, with their explanation in an info button.
- **Rows and headings:** `KVRow` is a spec row: label, value, hairline beneath; a symbol only for a warning. Section headings are words at display size, with a symbol only where it carries state.
- **Notices:** `hisNotice` draws the studio fill with a 2pt edge in the notice colour (4pt under Increase Contrast); text stays ink.
- **Settings and sign-in:** a text-only sidebar marked by a 2pt ink bar, a search field with a rule beneath, and the brand choice as an underlined row. Sign-in options are outlined tiles; the chosen one takes a 2pt ink edge.
- **Mini panel:** flat canvas with a hairline edge, battery as a figure, power and time muted, and the gold charge line.
- **Charts:** in the Monochrome Precision palette, ink for the primary series, greys for supporting ones, a deep gold for attention.
- **Icons:** outline SF Symbols throughout; filled glyphs remain only for warning, success, and error marks.

## Motion and input

`Motion.swift` defines selection, press, refresh, command feedback, and gesture timing. The panel appears with opacity. A swipe or reorder can settle from a position carried by the pointer; telemetry stays anchored while its figures roll. Reduce Motion keeps a crossfade or resolves without movement. The stage, the rules, and the underline add no decorative motion.

The keyboard reaches the whole panel. ⌘1 to ⌘9 select the first nine tabs, ⌘R refreshes telemetry, and ⌘, opens Settings. ⌃⌥P toggles the panel, and ⌃⌥[ and ⌃⌥] or ⌃⌥1 to ⌃⌥9 change car. The ⌃⌥ keys also work while another app is active once macOS has granted the permission.

The reader chooses which of the seven control cards show on Now, and can hide and reorder tabs and the items inside them. The Now cards keep one fixed order: Locks, Climate, Charging, Air Cleaning, Windows, Honk & Flash, Tailgate.

### Open candidates

Neither of these is decided or built. Do not implement either without a decision from the owner.

- **Shortcuts for the three frequent actions.** Lock, climate, and charging are what readers do most, and none has a shortcut. A shortcut would send a command to the car from a keystroke. It needs the same capability gate the cards use today, and a decision on whether a keystroke should ask before it sends, since remote commands show no confirmation dialog now.
- **Reorderable Now cards.** The tab composition screen already has reorder controls that work by drag and by button. Reusing them would let a card keep the place the reader gave it.

## Brand boundary

Hisingen is an independent product with no affiliation to any vehicle maker. It ships no manufacturer wordmark or badge, no licensed typeface files, and no campaign imagery, and it keeps its own vehicle artwork path and outlines.

Theme names describe a colour or a place. None is named after a vehicle maker, a paint finish, or a racing team, and no theme name or subtitle contains a maker's name. `MeasurementUnitsAndThemeTests` checks every theme's title and subtitle against a list of names that must not appear. The two themes that used to carry such names are now Charcoal Gold and Circuit Blue. A saved choice made under an old identifier is rewritten at launch and when a settings archive is imported, so no one loses their theme.

## Verification

Contrast is checked by `Scripts/verify-app-contrast.py`. `Scripts/verify-surface-discipline.mjs` and `Scripts/verify-ui-discipline.mjs` check shared surface, focus, type, and copy rules. For local snapshots of the production views with isolated sample vehicle data:

```sh
HISINGEN_PANEL_RENDERS=/tmp/hisingen-panel sh Scripts/test.sh --filter PanelInspectionTests --no-parallel
```

The Unslopovich visit in `.unslopovich/visits/` records what ran, what was inspected, and the limits of that evidence.
