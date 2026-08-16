# Component Map

The architecturally significant pieces, one per section. Each states what it owns, how it's isolated, and how it fails. File-level detail (every SwiftUI view, every DTO) is deliberately left out — read the source for that.

## AppDelegate (`App/AppDelegate.swift`)

**Purpose:** app shell — the only `NSApplicationDelegate`, owns the single instances of everything else.

**Responsibilities:** installs the menu bar, migrates the legacy plaintext password, constructs `StatusItemController`/`RefreshCoordinator`/`Notifier`/`UpdateChecker`/`RemoteActionAuthorizer`, wires every callback between them, resumes a stored session at launch, handles brand switching (`switchActiveBrand`), dispatches remote commands, handles the `hisingen://` URL callback.

**Main types:** `AppDelegate`.

**Dependencies:** `PolestarAPI`, `VolvoAPI`, `RefreshCoordinator`, `StatusItemController`, `Notifier`, `UpdateChecker`, `RemoteActionAuthorizer`, `VolvoSignInPresenter`, `Preferences`, `Keychain`.

**State it owns:** `latest: VehicleState?`, `lastError`, `sessionValid`, `lastDiagnostics`, `remoteCommandInProgress`, and which `VehicleProviding` (`activeProvider`) is currently active.

**Isolation:** `@MainActor` class.

**Inputs:** OS lifecycle callbacks, `RefreshCoordinator` callbacks, UI closures from `StatusItemController`.

**Outputs:** calls `statusController.render(...)` to push state into the UI; issues remote commands to `activeProvider`.

**Failure modes:** a provider throwing `requiresAuthentication` flips `sessionValid = false` and (if the Notifications feature is on) triggers an auth-required local notification. Remote command failures surface as an `NSAlert`, never crash the app.

## RefreshCoordinator (`Services/Refresh/RefreshCoordinator.swift`)

Owns the entire polling lifecycle for one `VehicleProviding` instance. See [refresh-system.md](refresh-system.md) for the full write-up — summary here:

**Purpose:** prevent timer, manual, wake, and network-recovery refreshes from racing each other or hammering the backend, and turn provider errors into UI-facing diagnostics.

**Main types:** `RefreshCoordinator`, `RefreshPolicy`, `DiagnosticsSnapshot`, `Trigger`.

**State it owns:** in-flight `Task`, a `generation` counter, `failureCount`, `rateLimitedUntil`, `sleeping`, `networkAvailable`, the `NWPathMonitor`, and the last known `VehicleState`/`[CarSummary]`.

**Isolation:** `@MainActor` class. Its `NWPathMonitor` callback runs on a private `DispatchQueue` and hops back via `Task { @MainActor in ... }` before touching any state.

**Failure modes:** every failure is classified via `VehicleServiceError.isTransient`/`.requiresAuthentication` and either retried with backoff or surfaced through `onError`.

**Relevant tests:** `Tests/HisingenTests/Unit/RefreshCoordinatorTests.swift`, `ChargingTransitionDetectorTests.swift` (shares the backoff-formula tests).

## PolestarAPI (`Services/API/PolestarAPI.swift`) + PolestarGRPC*

**Purpose:** the `VehicleProviding` conformance for Polestar. Owns OIDC login, GraphQL calls, and dispatches to a hand-rolled gRPC client for everything GraphQL doesn't cover.

**Main types:** `actor PolestarAPI`, `actor PolestarGRPC`, `PolestarGRPCCapabilities` (extension), `PolestarGRPCRemote` (extension), `PolestarError`.

**State it owns:** access/refresh token and expiry (in-memory only — only the refresh token is persisted), `cars`, per-VIN capability cache and backoff tables, the discovered C3 gRPC host, an ephemeral `URLSession` (recreated on `resetSession()`).

**Isolation:** `actor`. Token refresh and C3 host discovery both use the "single stored `Task`, everyone awaits it" pattern to prevent duplicate concurrent requests.

**Failure modes:** see [api/polestar.md](../api/polestar.md#error-handling) and [architecture/capabilities.md](capabilities.md) — a failed optional-capability fetch degrades that one field, not the whole refresh.

**Relevant tests:** `GraphQLDecodingTests`, `VehicleCapabilityParsingTests`, `RequestConstructionTests`, `ResumePathTests`, `RemoteCommandTests`, plus `Integration/LivePolestarIntegrationTests.swift` (credential-gated, opt-in).

## VolvoAPI (`Services/API/VolvoAPI.swift`)

**Purpose:** the `VehicleProviding` conformance for Volvo. Owns OAuth2 PKCE login against Volvo ID and all REST calls to Volvo's Connected Vehicle / Energy / Location APIs.

**Main types:** `actor VolvoAPI`, `VolvoError`, DTOs in `VolvoModels.swift`.

**State it owns:** access/refresh token and expiry, `cars`, per-VIN vehicle-details/capability caches, per-endpoint backoff table, `remoteCommandsInFlight`.

**Isolation:** `actor`. Same single-stored-`Task` refresh-coalescing pattern as `PolestarAPI`.

**Failure modes:** see [api/volvo.md](../api/volvo.md#error-handling).

**Relevant tests:** `VolvoDecodingTests`, `VolvoModelIdentificationTests`, `VolvoKeychainIsolationTests`, plus `Integration/LiveVolvoIntegrationTests.swift` (credential-gated, opt-in).

## VehicleProviding (`Services/API/VehicleProviding.swift`)

**Purpose:** the seam. A 9-method protocol both providers conform to; everything above this line in the app is brand-agnostic. See [providers.md](providers.md).

## Domain model (`Domain/*.swift`)

**Purpose:** the shared vocabulary — `VehicleState`, `VehicleCapabilityProfile`/`VehicleProbedCapabilities`, `RemoteCommand`, `AppFeature`, `VehicleModelFamily`.

**Main types:** see [domain/vehicle.md](../domain/vehicle.md) for the full model.

**State it owns:** none — these are value types (`struct`/`enum`), all `Sendable`, `Codable`. `VehicleState.mergingLastKnown(from:features:)` is the one non-trivial piece of behavior living here — see [data-flow.md](data-flow.md).

## Notifier + ChargingTransitionDetector (`Services/Notifications/*.swift`)

**Purpose:** turn consecutive `VehicleState` snapshots into local notifications, without spamming the same event twice.

**Main types:** `Notifier` (`@MainActor`, `UNUserNotificationCenterDelegate`), `ChargingTransitionDetector` (stateless `struct`), `ChargingBaseline` (persisted state).

**State it owns:** `Notifier` owns `previousStateByVIN`, notification-permission status, and an "auth notice already posted" flag. `ChargingTransitionDetector` owns nothing — it's a pure function from `(previous baseline, current state) → (events, new baseline)`.

**Isolation:** `Notifier` is `@MainActor`. `ChargingTransitionDetector` needs no isolation — it's a value type.

**Failure modes:** disabled entirely when not running as a real `.app` bundle (`swift test`/CLI), so the test suite never posts real notifications.

**Relevant tests:** `ChargingTransitionDetectorTests`, `RegressionFixTests` (rain/evening-unlocked conditions).

See [domain/notifications.md](../domain/notifications.md).

## Persistence trio (`Services/Persistence/*.swift`)

**Keychain.swift** — `KeychainStore` (value type) + `InMemorySecretCache` (the one manual-lock singleton in the codebase). Stores Polestar's password/refresh-token and Volvo's client-secret/API-key/refresh-token, each brand in its own Keychain account.

**Preferences.swift** — `@MainActor enum Preferences`, a typed façade over `UserDefaults` for every non-secret setting (VIN, nicknames, feature selection, notification toggles, theme, etc.).

**VehicleStateStore.swift** — plain `final class`, `UserDefaults`-backed cache of the last `VehicleState` and `ChargingBaseline` per VIN, both with a 7-day self-cleaning TTL.

See [persistence.md](persistence.md) and [security/keychain.md](../security/keychain.md).

## RemoteActionAuthorizer + VolvoSignInPresenter (`Services/Security/*.swift`)

**RemoteActionAuthorizer** — `@MainActor` class. Shows an `NSAlert` confirmation for every remote command, and additionally requires `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` (Touch ID or Mac password) for `.securitySensitive`/`.destructive`-risk commands.

**VolvoSignInPresenter** — `@MainActor` class. Drives Volvo's OAuth flow through the system browser (`NSWorkspace.shared.open`, not `ASWebAuthenticationSession`) and resumes a suspended continuation when the `hisingen://` callback URL arrives.

See [api/authentication.md](../api/authentication.md).

## ReverseGeocoder (`Services/Location/ReverseGeocoder.swift`)

**Purpose:** turn vehicle coordinates into a street address using Apple's `CLGeocoder`, with an in-memory-only cache.

**Isolation:** true Swift `actor` — the one component in the codebase with no `@MainActor`/manual-lock caveat.

## UpdateChecker (`Services/Updates/UpdateChecker.swift`)

**Purpose:** poll the GitHub Releases API at most once per 24 hours, compare semantic versions, skip drafts/prereleases.

**Isolation:** `@MainActor` class, single in-flight `Task` with a `waitingCallbacks` array for coalescing.

## UI (`UI/*.swift`)

**Purpose:** render `VehicleState`/`VehicleCapabilityProfile` and turn user actions into closures back up to `AppDelegate`.

**Main types:** `StatusItemController` (AppKit: `NSStatusItem`, `NSPopover`, global hotkeys, context menu), `HisingenContentView` (SwiftUI root), `VehicleTabView`, `ControlsTabView`, `SettingsView`, `AccountCredentialsForm`, `WelcomeSignInView`, `HisingenTheme` (design system).

**Isolation:** everything is declared `@MainActor` — there is no cross-actor hop between AppKit and SwiftUI in this app; `StatusItemController` pushes state into SwiftUI by rebuilding the view struct and reassigning `NSHostingController.rootView`, not via `ObservableObject`.

See [runtime.md](runtime.md#ui-bridging) for the exact bridging mechanism.
