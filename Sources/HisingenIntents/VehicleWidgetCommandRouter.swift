import Foundation

/// The host app's side of the shared intent seam.
///
/// The widget extension links this module but never the app, so the app installs the real
/// dispatcher at launch. Every widget-facing intent runs with `openAppWhenRun`, which puts
/// `perform()` in the app process, where this handler exists and where the command takes
/// the same capability gates, confirmation and audit path as any other control.
@MainActor
public protocol VehicleWidgetCommandHandling: AnyObject, Sendable {
    /// Sends `command` for `vin` — nil means the app's active vehicle — and returns the
    /// sentence the intent presents. Throwing reports a failure without inventing success.
    func perform(_ command: VehicleWidgetCommand, vin: String?) async throws -> String
}

/// Process-wide seam between the shared intents and the app's command dispatcher.
///
/// The install is awaited rather than assumed: an intent can be performed while the app is
/// still finishing its launch, and the same continuation pattern the Shortcuts handoff uses
/// keeps that command queued instead of failing on an empty registry.
@MainActor
public enum VehicleWidgetCommandRouter {
    private static var registered: (any VehicleWidgetCommandHandling)?
    private static var waiters: [UUID: CheckedContinuation<any VehicleWidgetCommandHandling, Never>] = [:]

    /// Installed once the app's composition is complete, beside the Shortcuts handoff.
    public static func install(_ handler: any VehicleWidgetCommandHandling) {
        registered = handler
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(returning: handler) }
    }

    /// True after the app registered its dispatcher, so tests and diagnostics can tell an
    /// unlaunched app from an installed one.
    public static var isInstalled: Bool { registered != nil }

    /// Returns the sentence to present. Nil means no app has registered a handler; the
    /// intent then asks the reader to open Hisingen instead of failing silently.
    static func send(_ command: VehicleWidgetCommand, vin: String?) async throws -> String? {
        guard let handler = await installedHandler() else { return nil }
        return try await handler.perform(command, vin: vin)
    }

    private static func installedHandler() async -> (any VehicleWidgetCommandHandling)? {
        if let registered { return registered }
        // An extension process can never receive the app's install, so it reports the
        // missing handler instead of waiting for one. In the app the launch install always
        // arrives; an intent performed mid-launch waits exactly as the Shortcuts handoff does.
        if Bundle.main.bundleURL.pathExtension == "appex" { return nil }
        return await withCheckedContinuation { continuation in
            waiters[UUID()] = continuation
        }
    }

    #if DEBUG
    /// Test isolation for the process-wide registry.
    public static func resetForTesting() {
        registered = nil
        waiters = [:]
    }
    #endif
}
