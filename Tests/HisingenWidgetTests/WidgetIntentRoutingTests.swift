import Testing
@testable import HisingenIntents

/// Pins the seam the widget buttons rely on: the shared intent types open the app, and the
/// router hands each command and vehicle to whatever the app installed. Serialized because the
/// registry is process-wide, like `AutomationHandoff`.
@Suite("Widget intent routing", .serialized)
struct WidgetIntentRoutingTests {
    @MainActor
    private final class Recorder: VehicleWidgetCommandHandling {
        var commands: [VehicleWidgetCommand] = []
        var vins: [String?] = []
        var answer = "sent"

        func perform(_ command: VehicleWidgetCommand, vin: String?) async throws -> String {
            commands.append(command)
            vins.append(vin)
            return answer
        }
    }

    @Test
    func everyWidgetIntentRunsInTheApp() {
        #expect(WidgetLockVehicleIntent.openAppWhenRun)
        #expect(WidgetUnlockVehicleIntent.openAppWhenRun)
        #expect(WidgetStartClimateIntent.openAppWhenRun)
        #expect(WidgetRefreshVehicleIntent.openAppWhenRun)
    }

    @Test
    func theWidgetFacingCommandsAreTheFourButtons() {
        #expect(Set(VehicleWidgetCommand.allCases) == Set([.lock, .unlock, .startClimate, .refresh]))
    }

    @Test
    @MainActor
    func routerHandsTheCommandAndVehicleToTheApp() async throws {
        VehicleWidgetCommandRouter.resetForTesting()
        defer { VehicleWidgetCommandRouter.resetForTesting() }

        let recorder = Recorder()
        VehicleWidgetCommandRouter.install(recorder)

        let message = try await VehicleWidgetCommandRouter.send(.startClimate, vin: "YSMWIDGET01")

        #expect(message == "sent")
        #expect(recorder.commands == [.startClimate])
        #expect(recorder.vins == ["YSMWIDGET01"])
    }

    /// The refused command's own sentence is what the intent wraps in its dialog, so a refusal
    /// is shown rather than swallowed by the widget.
    @Test
    @MainActor
    func aRefusalReachesTheIntentDialog() async throws {
        VehicleWidgetCommandRouter.resetForTesting()
        defer { VehicleWidgetCommandRouter.resetForTesting() }

        let recorder = Recorder()
        recorder.answer = "Remote commands are turned off."
        VehicleWidgetCommandRouter.install(recorder)

        let message = try await VehicleWidgetCommandRouter.send(.lock, vin: nil)

        #expect(message == "Remote commands are turned off.")
        #expect(recorder.commands == [.lock])
        #expect(recorder.vins == [nil])
    }
}
