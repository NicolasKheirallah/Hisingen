# Data Retention

Hisingen stores vehicle snapshots, charging history, battery-health milestones, telemetry, and
remote-command audit records locally for the signed-in macOS user.

## Defaults

- Cached vehicle snapshots older than 7 days are not served.
- Charging samples and telemetry are pruned after 90 days by the maintenance action.
- Charging-session headers are retained when their samples are pruned.
- Battery-health milestones are retained for long-term degradation tracking.
- Remote-command audit records are retained until the user signs out or clears application data.

## User Controls

The Settings maintenance actions are the authoritative way to prune history or clear all stored
vehicle data. Sign-out clears cached vehicle snapshots and credentials; it does not remove the
application database unless the user explicitly clears stored history.

The database contains VINs and may contain location coordinates. It must not be copied into logs,
diagnostic bundles, or release artifacts.
