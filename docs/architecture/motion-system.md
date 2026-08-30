# Motion system

Hisingen's animation language is **Polestar restraint + Volvo clarity + Apple-level
polish**. Motion exists to make vehicle state, user actions and background activity
legible — never as decoration. Individually most animations should be barely
noticeable; together they should make the app feel physical and deliberate.

This document covers the *shared* motion system. The vehicle hero-image roll-in has
its own, deeper treatment in [vehicle-motion.md](vehicle-motion.md); it predates
this system and feeds a couple of tokens back into it (the entrance timing curve).

## Where the tokens live

`Sources/Hisingen/UI/Motion.swift` — the `Motion` enum, the animation counterpart
of `HisingenTheme`. Nothing that animates should spell a duration or a spring
inline; it resolves one from `Motion` instead, so "the same concept animates the
same way" holds across the app.

Tokens are grouped by **why** the animation runs:

| Group | When it runs | Character | Example tokens |
|---|---|---|---|
| **Interaction** | A direct response to the user — press, hover, navigation, toggle. | Short, immediate, no overshoot. The control acknowledges input before anything else. | `interaction`, `selection`, `disclosure`, `micro` |
| **State** | The vehicle changed — charging started, doors unlocked, climate on. | Slightly more expressive. A critically-damped spring: settles once, never rings. | `stateChange`, `cardChange`, `layout` |
| **Entrance / exit** | Content arriving or leaving. | Quick off the mark, long gentle tail (the deceleration the vehicle roll-in ends on). Exits are prompt. | `entrance`, `exit` |
| **Telemetry** | A new provider reading replacing an old one. | A slow settle, not a flicker. Never implies Hisingen samples the car faster than it does. | `telemetry`, `progress` |
| **Ambient** | An ongoing condition — charging, climate running, a live stream. | Very quiet, very slow, cheap enough to run for hours. Two *close* visual states, never a large move. | `breath`, `livePulse`, `spin`, `chargeFlow*` |

### Duration ladder

`micro` (0.11 s) · `fast` (0.2 s) · `standard` (0.32 s) · `large` (0.5 s) ·
`deliberate` (0.66 s, the manual-refresh sweep) — then the ambient cycles, which
are measured in whole seconds (`breathCycle` 2.6 s, `menuBarBreathCycle` 3.6 s).

## Reduce Motion

Resolved in **one place**: `Motion.prefersReducedMotion`, which delegates to
`VehicleMotionPreference.prefersReducedMotion` (also used by the AppKit
vehicle-motion code, and hookable from tests via `reduceMotionOverride`).

- `Motion.resolve(_:)` returns `nil` when the user asked for less motion — for
  AppKit, `TimelineView` drivers and plain models.
- `Motion.resolveCrossfade(_:)` keeps a short opacity cross-fade under Reduce
  Motion, so a state change is still *noticed*, just not moved.
- SwiftUI views keep reading `@Environment(\.accessibilityReduceMotion)` and pass
  the bool to the helpers below.

Charging stays identifiable with all motion disabled: the charging *glyph*
(`bolt.car.fill`) and the static progress values carry the meaning; only the
breath and the energy-flow sweep drop out.

## View helpers

- `View.hisTelemetryValue(_:reduceMotion:)` — the standard treatment for a numeric
  telemetry label: pairs `.contentTransition(.numericText())` with
  `Motion.telemetry`, collapsing to an instant swap under Reduce Motion. Replaces
  the two-line `.contentTransition + .animation` pair that was copy-pasted across
  the battery, range, charge-target and charging labels. This is the "61 % → 62 %"
  transition.
- `View.hisAnimation(_:value:reduceMotion:)` — `.animation` that drops the tween
  under Reduce Motion.
- `PressableButtonStyle` (`.buttonStyle(.pressable)` / `.pressableSoft`) — the
  "every interactive control acknowledges input" primitive: a small compression
  and dim on press, springing back on `Motion.interaction`. Honours Reduce Motion
  (keeps a faint opacity change, drops the scale).

## Menu bar / tray icon

`Sources/Hisingen/UI/Shell/MenuBarPresentation.swift`.

The tray glyph is a permanent ambient status light. `MenuBarIconState` is a
priority-ordered enum — higher wins when several conditions hold at once:

```
critical warning  >  active remote operation  >  charging complete
   >  charging  >  climate active  >  connected  >  normal
```

`MenuBarIconState.resolve(_:)` is a pure function over `MenuBarIconInputs` (plain
`Bool`s), so the priority logic is unit-tested without constructing a
`VehicleState`. `MenuBarIconState.inputs(for:remoteCommandInProgress:chargingRecentlyCompleted:)`
reads the signals off a snapshot; the charging → complete edge is a transition,
tracked by `StatusItemController`, not a field on the state.

`MenuBarIconAnimator` drives the `NSStatusItem` button image for the two animated
states (`charging`, `remoteOperation`). Efficiency is the whole brief — it can run
for a multi-hour charge:

- **Frame cache.** One breathing cycle is pre-rendered into `MenuBarPulseProfile.frames`
  `NSImage`s once; each tick is then a pointer assignment, not a redraw.
- **Coarse cadence.** ~5 fps for the charging breath (18 frames over 3.6 s). The
  glyph alpha follows a raised cosine, so it eases at both extremes and the loop
  has no visible seam.
- **Paused when unseen.** The timer stops on `screensDidSleepNotification` and
  restarts on wake; a still state carries no timer at all.
- **Reduce Motion.** Falls straight through to the static base image.

Completion is a fixed dwell (`Motion.menuBarCompletionDwell`, 4 s): the pulse
stops, the glyph rests bright, then the resting plugged-in glyph takes over.
`StatusItemController.scheduleCompletionExpiry()` nudges one re-render when the
dwell lapses, because no provider event will.

## Charging, specifically

Charging is a signature detail, so it gets consistent ambient motion everywhere it
appears:

- **Charging card / `CardHeader`** — a ~6 % swell on `Motion.breath`, plus a
  `checkmark.circle.fill` that springs in on `Motion.cardChange` when a session
  finishes (a settle, not a celebration).
- **`BatteryGauge`** — a flowing energy highlight (`ChargingFlowHighlight`, a
  `TimelineView` sweep at `Motion.chargeFlowPointsPerSecond`) and a breathing glow
  on `Motion.breath`. The fill fraction moves on `Motion.progress`.
- **Floating `ChargingMiniPanel`** — the hosting view is kept alive across
  telemetry updates so SwiftUI cross-fades new readings in via `hisTelemetryValue`
  instead of the panel being rebuilt; the bolt glyph breathes.
- **Menu bar** — the pulse described above.

## Adding motion

1. Reach for an existing `Motion` token. If nothing fits, add a token — don't
   inline a new duration.
2. Decide the group (interaction / state / entrance / telemetry / ambient) and
   match its character.
3. Gate it on Reduce Motion via the helpers or `Motion.resolve`.
4. For anything ambient, confirm it pauses when the view is gone and that its
   cadence is as slow as it can be. Pre-render frames rather than redrawing per
   tick where the surface is long-lived.
