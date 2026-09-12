import Foundation
import Testing
@testable import Hisingen

/// Which bundled Hisingen artwork the menu bar shows for a set of signals —
/// the drawable half of `MenuBarIconState`'s priority machine. The PNGs
/// themselves are judged on screen; this covers the logic that picks them.
@Suite
struct MenuBarGlyphTests {

    @Test
    func restingStateUsesTheNormalGlyph() {
        XCTAssertEqual(MenuBarGlyph.resolve(inputs: MenuBarIconInputs(), offline: false), .normal)
    }

    @Test
    func offlineWinsOverEverythingElse() {
        // No data (or stale data) is the loudest statement the bar can make —
        // even a charging fault cannot be drawn on top of "not connected".
        let inputs = MenuBarIconInputs(
            isCharging: true, pluggedIn: true, climateActive: true, alarmTriggered: true
        )
        XCTAssertEqual(MenuBarGlyph.resolve(inputs: inputs, offline: true), .offline)
    }

    @Test
    func criticalWarningUsesTheWarningGlyph() {
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: MenuBarIconInputs(alarmTriggered: true), offline: false),
            .warning
        )
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: MenuBarIconInputs(chargingFault: true, pluggedIn: true), offline: false),
            .warning
        )
    }

    @Test
    func chargingOutranksCompletionClimateAndConnected() {
        let inputs = MenuBarIconInputs(
            isCharging: true, chargingRecentlyCompleted: true,
            pluggedIn: true, climateActive: true
        )
        XCTAssertEqual(MenuBarGlyph.resolve(inputs: inputs, offline: false), .charging)
    }

    @Test
    func completionShowsTheFullyChargedGlyphOnlyAfterChargingStops() {
        let done = MenuBarIconInputs(chargingRecentlyCompleted: true, pluggedIn: true)
        XCTAssertEqual(MenuBarGlyph.resolve(inputs: done, offline: false), .fullyCharged)
    }

    @Test
    func climateOutranksConnectedButNotCharging() {
        let preconditioning = MenuBarIconInputs(pluggedIn: true, climateActive: true)
        XCTAssertEqual(MenuBarGlyph.resolve(inputs: preconditioning, offline: false), .climateActive)

        let charging = MenuBarIconInputs(isCharging: true, pluggedIn: true, climateActive: true)
        XCTAssertEqual(MenuBarGlyph.resolve(inputs: charging, offline: false), .charging)
    }

    @Test
    func pluggedInIdleUsesThePluggedInGlyph() {
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: MenuBarIconInputs(pluggedIn: true), offline: false),
            .pluggedIn
        )
    }

    @Test
    func aRemoteCommandShimmersTheCurrentGlyphInsteadOfReplacingIt() {
        let charging = MenuBarIconInputs(isCharging: true, pluggedIn: true)
        let busy = MenuBarIconInputs(isCharging: true, pluggedIn: true, remoteCommandInProgress: true)
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: busy, offline: false),
            MenuBarGlyph.resolve(inputs: charging, offline: false)
        )
    }

    @Test
    func connectionGlyphsDisabledCollapseToTheRestingCar() {
        // Mirrors the legacy `includeConnection: false` gate: with "Charging
        // details" off, charging/plugged/completion artwork hides.
        let charging = MenuBarIconInputs(isCharging: true, pluggedIn: true)
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: charging, offline: false, connectionGlyphsEnabled: false),
            .normal
        )
        let completed = MenuBarIconInputs(chargingRecentlyCompleted: true, pluggedIn: true)
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: completed, offline: false, connectionGlyphsEnabled: false),
            .normal
        )

        // Climate and warnings are not connection details — they still surface.
        let preconditioning = MenuBarIconInputs(pluggedIn: true, climateActive: true)
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: preconditioning, offline: false, connectionGlyphsEnabled: false),
            .climateActive
        )
        XCTAssertEqual(
            MenuBarGlyph.resolve(inputs: MenuBarIconInputs(alarmTriggered: true), offline: false, connectionGlyphsEnabled: false),
            .warning
        )
    }

    @Test
    func everyGlyphHasADistinctResourceAndAnSFFallback() {
        let resources = Set(MenuBarGlyph.allCases.map(\.resourceName))
        XCTAssertEqual(resources.count, MenuBarGlyph.allCases.count)
        for glyph in MenuBarGlyph.allCases {
            XCTAssertFalse(Format.symbolFallback(for: glyph).isEmpty, "\(glyph) SF fallback")
        }
    }
}
