# Remote controls

[Documentation](README.md) · [Control screenshots](product-tour.md#plan)

## Supported commands

These commands are available on compatible vehicles after you enable the remote features you want.

| Function               |    Polestar   | Volvo |
| ---------------------- | :-----------: | :---: |
| Climate start / stop   |       ✓*      |   ✓*  |
| Lock / unlock          |       ✓*      |   ✓*  |
| Lock with reduced guard |      —       |   ✓*  |
| Horn / lights          |       ✓*      |   ✓*  |
| Window controls        |       ✓*      |   —   |
| Tailgate controls      |       ✓*      |   —   |
| Cabin cleaning         |       ✓*      |   —   |
| Charge target          |       ✓*      |   —   |
| Charging-current limit |       ✓*      |   —   |
| Charging override      |       ✓*      |   —   |
| Charging schedules     |       ✓*      |   —   |
| Saved charge locations |       ✓*      |   —   |
| Climate schedules      |       ✓*      |   —   |
| OTA controls           | Experimental* |   —   |
| Engine start / stop    |       —       |   ✓*  |

\* Availability still depends on the vehicle, account and services available for that car.

For sensitive commands such as unlocking the car, Hisingen can require device-owner authentication through Touch ID, Apple Watch, or the Mac password, depending on what macOS makes available.

## Home charger commands

A paired home charger has two commands of its own, **Charge Now** and **Pause**. They go to the
charger through its vendor's cloud or through Home Assistant, not through the vehicle, so they are
not part of the table above and do not depend on what the car supports. A command stays pending in
words until the charger's own reading, stamped after the command was accepted, confirms it. A
window that closes without one is reported as unconfirmed and not as success. The vendors differ:
Zaptec has no start, so Charge Now resumes a pause or a schedule, and Easee's pause sets the dynamic
current to 0. [Home charging](home-charging.md#charger-commands-and-what-done-means) has the
details for each charger, and the
[architecture page](architecture/home-charging.md#polling-and-the-command-loop) describes the loop.

## What the car reports decides what you see

On Polestar, Hisingen uses the car's capability record (`GetMyCars`) to decide which controls to offer.

* central locking and reduced-guard locking follow the reported lock type; reduced-guard locking
  is reported where the car advertises it, but the control is Volvo-only because the Polestar
  transport has no such command
* remote unlock follows the reported unlock type. A trunk-only car keeps the tailgate control, and
  a disabled Unlock on a car whose unlock type is none says why
* preconditioning follows the reported climatization type, and charge timers and saved charge
  locations follow the reported charging capabilities
* honk and flash follows the per-vehicle mode the car reports. A car that reports none gets no
  honk or flash control

On Volvo, controls follow the command list the API returns for that VIN, and the Approved
permissions scope is required for lock, honk and engine start and stop. EX30, EX90 and ES90 are not
offered climate setpoints, windows, trunk or charging controls that the public API cannot perform.

## Retry, Undo and routines

* **Retry** is offered on a failed command only when the failure proves it did not run.
* **Undo** is offered for 30 seconds on a reversible command.
* **Routines** (Plan tab) are saved sequences of commands. Each step goes through the same
  capability check and authorization as a single command, steps run in order, and a routine stops
  at the first failure.

## Automations

**Settings → Automations** can run actions without you present. Three kinds exist, and all of them
are empty until you add something:

* **Scheduled actions** run one command at a wall-clock time on the days you choose. An action that
  fires more than fifteen minutes late is skipped rather than replayed, so a Mac that wakes at
  breakfast does not lock the car six hours late.
* **Arrival and departure** triggers run a command when the car reaches or leaves a saved charge
  location. The comparison happens inside Hisingen, using the position the car already reports and
  the coordinates of the locations you saved — no Location Services permission is requested, and
  triggers only fire while Hisingen is running. The first snapshot after launch records where the
  car is; it does not count as an arrival.
* **Send to every vehicle** sends one command to each car on the connected account, one at a time,
  and names the ones that did not answer.

Unattended sends share one queue and one per-command cooldown: a command already on its way is not
sent twice, and a repeat inside the cooldown is refused with the wait spelled out. Only actions that
need no confirmation can be scheduled or triggered; unlocking, opening windows and anything else a
person must approve stays a deliberate tap in the Controls tab.

## When a command's outcome is uncertain

A Polestar command waits up to 15 seconds for the car's reply. Polestar's backend keeps some
streams open after it has answered, so a complete reply followed by that deadline counts as
success. A deadline inside a reply, or before any reply, is reported as an unknown outcome ("The
command may have reached the vehicle"), because Hisingen cannot tell whether it ran. A deadline is
reported as a deadline and never as you cancelling.

## Authorizing remote commands (Polestar)

Commands such as lock, climate and honk need a second sign-in grant. With a working Polestar ID
session, choose **Authorize Remote Commands** under **Settings → Accounts → Remote Controls**
or from the banner that appears if a command needs it. If authorization fails, the alert names
the step that failed. See which grant each command uses in the
[Polestar command mappings](api/field-mappings.md#polestar-which-call-carries-each-command).

## Command line

`hisingen cli` sends a command from a terminal. It is not a second command path: it resolves a
vehicle, then hands the command to the same capability check, the same confirmation step, the same
provider call, the same history row and the same command receipt this tab, the `hisingen://` links
and the Shortcuts intents use. A command the app would refuse is refused here, in the app's own
words.

The command line is a mode of the app binary, so it answers from the app's own code:

```sh
"/Applications/Hisingen.app/Contents/MacOS/Hisingen" cli vehicles
```

From a checkout, `swift run Hisingen cli vehicles` works the same way. The app does not need to be
running: the terminal restores the account session, reads the same local database, and asks the
provider for a current reading before it sends anything.

```text
hisingen cli vehicles [--json] [--refresh]
hisingen cli send <command> [value] [--vin <vin or name>] [--confirm] [--json]
hisingen cli help
```

`--vin` takes a VIN this Mac knows, a saved nickname, or a model name, and resolves the way a
Shortcut's vehicle argument does. Without it the selected vehicle is used. `--refresh` asks the
provider for a current reading instead of using the last stored one. `--confirm` is the
confirmation step: a command this app asks about before sending — anything other than a routine
command, such as unlock, honk and flash, engine start, or a software install — is refused without
it, and device-owner authentication still runs where the app requires it.

| Code | Meaning |
| --- | --- |
| 0 | The provider accepted the command. |
| 1 | The surface itself failed. |
| 2 | Arguments it could not use: an unknown command or option, a value outside the ranges the app's own controls offer, or a vehicle name that matches nothing. |
| 3 | Refused: the capability check's answer, or the provider's. The sentence is the one this app's banner would show. |
| 4 | Not authorized: `--confirm` was missing, or device-owner authentication did not succeed. |
| 5 | Not sent, and safe to retry: another command was running, the data was still loading, or the session could not be restored. |

Text output puts a success on the standard output and a failure on the error stream, so logging a
command's output does not record a failure as a success. `--json` prints one object on the standard
output whatever happened, with `status`, `command`, `vin`, `vehicle`, `outcome` and `message`.
`vehicles --json` carries, for every vehicle, which one is selected, how old its reading is, and the
capability answer for each command with the reason for anything blocked.

It deliberately cannot send something this app would refuse, skip the confirmation, bypass the
history row or the receipt, change what the app has selected, sign in or out, edit settings, or ask
a car for a value no control in this app can produce.

## About Polestar remote controls

Polestar remote commands use undocumented interfaces and should be considered experimental.

They can change independently of Hisingen if Polestar changes its backend.

Hisingen tries to distinguish between a command being accepted by the server and the vehicle actually completing it whenever the available service makes that possible.
