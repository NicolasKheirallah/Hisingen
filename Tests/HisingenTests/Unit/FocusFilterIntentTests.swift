import Testing
@testable import Hisingen

/// The Focus filter's criteria mapping: which vehicle a Focus's arguments resolve to, what
/// gets written, and the summary Focus settings shows. Tested against a scoped preferences
/// store so no real mute list or active-vehicle choice is ever touched.
@MainActor
struct FocusFilterIntentTests {
    private let polestarVIN = "LPSABCDE12345678"
    private let volvoVIN = "YV1ZB2345K1234567"

    @Test("A blank vehicle argument resolves to the default vehicle")
    func blankVehicleMeansDefault() {
        let scoped = ScopedPreferences(label: "FocusBlank")
        scoped.store.setVin(polestarVIN, for: .polestar)

        let applied = FocusFilterMapping.resolve(vehicle: nil, policy: .muted, preferences: scoped.store)

        #expect(applied.vin == polestarVIN)
        #expect(applied.brand == .polestar)
        #expect(applied.muted)
    }

    @Test("A nickname argument resolves to that vehicle's VIN")
    func nicknameResolves() {
        let scoped = ScopedPreferences(label: "FocusNickname")
        scoped.store.setVin(polestarVIN, for: .polestar)
        scoped.store.setVin(volvoVIN, for: .volvo)
        scoped.store.setVehicleNickname("Familjebilen", for: polestarVIN)

        let applied = FocusFilterMapping.resolve(vehicle: "familjebilen", policy: .all, preferences: scoped.store)

        #expect(applied.vin == polestarVIN)
        #expect(applied.brand == .polestar)
        #expect(!applied.muted)
        #expect(applied.vehicleName == "Familjebilen")
    }

    @Test("A typed VIN that belongs to the Volvo account resolves to Volvo")
    func volvoVINResolvesToVolvo() {
        let scoped = ScopedPreferences(label: "FocusVolvo")
        scoped.store.setVin(volvoVIN, for: .volvo)

        let applied = FocusFilterMapping.resolve(vehicle: volvoVIN, policy: .all, preferences: scoped.store)

        #expect(applied.vin == volvoVIN)
        #expect(applied.brand == .volvo)
    }

    @Test("A name that matches nothing resolves to no vehicle, so nothing is applied")
    func unknownVehicleAppliesNothing() {
        let scoped = ScopedPreferences(label: "FocusUnknown")
        scoped.store.setVin(polestarVIN, for: .polestar)
        scoped.store.setMuted(true, for: polestarVIN)
        scoped.store.activeBrand = .volvo

        let applied = FocusFilterMapping.resolve(vehicle: "No such car", policy: .muted, preferences: scoped.store)
        FocusFilterMapping.apply(applied, to: scoped.store)

        #expect(applied.vin == nil)
        #expect(applied.brand == nil)
        #expect(scoped.store.activeBrand == .volvo)
        #expect(scoped.store.isMuted(vin: polestarVIN))
        #expect(FocusFilterMapping.displaySummary(applied)
            == L10n.text("No vehicle in Hisingen matches that name or VIN."))
    }

    @Test("Applying a muted policy writes the per-vehicle mute the Notifier reads")
    func applyMutesTheVehicle() {
        let scoped = ScopedPreferences(label: "FocusMute")
        scoped.store.setVin(polestarVIN, for: .polestar)
        scoped.store.activeBrand = .polestar

        let applied = FocusFilterMapping.resolve(vehicle: polestarVIN, policy: .muted, preferences: scoped.store)
        FocusFilterMapping.apply(applied, to: scoped.store)

        #expect(scoped.store.isMuted(vin: polestarVIN))
        #expect(scoped.store.activeBrand == .polestar)
    }

    @Test("Applying the all policy clears a mute from an earlier Focus")
    func applyClearsAnEarlierMute() {
        let scoped = ScopedPreferences(label: "FocusUnmute")
        scoped.store.setVin(volvoVIN, for: .volvo)
        scoped.store.setMuted(true, for: volvoVIN)
        scoped.store.activeBrand = .polestar

        let applied = FocusFilterMapping.resolve(vehicle: volvoVIN, policy: .all, preferences: scoped.store)
        FocusFilterMapping.apply(applied, to: scoped.store)

        #expect(!scoped.store.isMuted(vin: volvoVIN))
        #expect(scoped.store.activeBrand == .volvo)
    }

    @Test("The summary names the vehicle and the policy it just applied")
    func displaySummaryNamesVehicleAndPolicy() {
        let scoped = ScopedPreferences(label: "FocusSummary")
        scoped.store.setVin(polestarVIN, for: .polestar)
        scoped.store.setVehicleNickname("Familjebilen", for: polestarVIN)

        let muted = FocusFilterMapping.resolve(vehicle: nil, policy: .muted, preferences: scoped.store)
        #expect(FocusFilterMapping.displaySummary(muted) == L10n.format("%@: notifications muted", "Familjebilen"))

        let on = FocusFilterMapping.resolve(vehicle: nil, policy: .all, preferences: scoped.store)
        #expect(FocusFilterMapping.displaySummary(on) == L10n.format("%@: notifications on", "Familjebilen"))
    }

    @Test("The policy enum the system stores per Focus is the two states Hisingen persists")
    func policyRawValues() {
        #expect(FocusNotificationPolicy.all.rawValue == "all")
        #expect(FocusNotificationPolicy.muted.rawValue == "muted")
        #expect(FocusNotificationPolicy.allCases.count == 2)
    }
}
