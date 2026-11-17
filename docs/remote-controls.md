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

## About Polestar remote controls

Polestar remote commands use undocumented interfaces and should be considered experimental.

They can change independently of Hisingen if Polestar changes its backend.

Hisingen tries to distinguish between a command being accepted by the server and the vehicle actually completing it whenever the available service makes that possible.
