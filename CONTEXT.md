# Domain context

## Glossary

**Vehicle State** — One coherent observation of a vehicle assembled from the provider data available during a refresh.

**Energy and Charging snapshot** — Battery, range, charging-session, and charger readings that describe stored energy and its transfer.

**Vehicle Identity and Factory Specification** — Stable identifying and build-time facts about a vehicle, including its VIN, model, market, finish, and configured equipment.

**Maintenance and Health snapshot** — Service needs, warnings, brake condition, warranty coverage, and other reported health information.

**Snapshot Freshness** — Provenance and timing facts that distinguish live readings, retained readings, and cached state.

**Command receipt** — Display state for a provider-accepted remote command. `RefreshCoordinator` owns its lifecycle from awaiting through confirmed or timed out. A separate per-vehicle receipt record survives relaunch; persisted vehicle telemetry remains receipt-free.

**Remote Command target** — The vehicle identity and provider captured when a command is approved. It remains fixed until execution completes, even if the visible vehicle selection changes.
