import AppKit
import SwiftUI
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct PolestarTelemetryPresentationTests {
    @Test func unspecifiedHeaterRequestsDifferFromExplicitOff() {
        #expect(CabinThermalMatrix.heaterLevelText(nil) == L10n.text("Not reported"))
        #expect(CabinThermalMatrix.heaterLevelText(0) == L10n.text("Off"))
        #expect(CabinThermalMatrix.heaterLevelText(3) == L10n.format("Level %d", 3))
        #expect(CabinThermalMatrix.heaterLevelText(4) == L10n.text("Not reported"))
        let matrix = CabinThermalMatrix(driverSeatLevel: nil, passengerSeatLevel: 0,
                                        steeringWheelLevel: 3, interiorTemperatureCelsius: nil,
                                        requestedTemperatureCelsius: 22, activity: .heating)
        let summary = matrix.accessibilitySummary
        #expect(summary.contains("\(L10n.text("Driver Seat")): \(L10n.text("Not reported"))"))
        #expect(summary.contains("\(L10n.text("Passenger Seat")): \(L10n.text("Off"))"))
        #expect(summary.contains(L10n.format("%@: level %d", L10n.text("Steering Wheel"), 3)))
        #expect(summary.contains(L10n.text("Heater requests may differ from automatic heating in the car.")))
    }

    @Test(arguments: [("ABANDONED", "Abandoned"), ("INACTIVE", "Inactive"),
                      ("CONVENIENCE", "Convenience"), ("ACTIVE", "Active"),
                      ("DRIVING", "Driving"), ("ENGINE_ON", "Engine Running"),
                      ("ENGINE_OFF", "Engine Stopped")])
    func operatingModeTokensHaveLocalizedNames(token: String, key: String) {
        let raw = VehicleIdentitySnapshot(availability: .unknown, vin: "TEST", usageMode: token)
        let portal = VehicleIdentitySnapshot(availability: .unknown, vin: "TEST", usageMode: "USAGE_MODE_" + token)
        #expect(raw.usageModeDisplayName == L10n.text(key))
        #expect(portal.usageModeDisplayName == raw.usageModeDisplayName)
    }

    @Test func missingAndFutureModesRemainHonest() {
        for value in [nil, "", "0", "USAGE_MODE_UNSPECIFIED"] as [String?] {
            let identity = VehicleIdentitySnapshot(availability: .available, vin: "TEST", usageMode: value)
            #expect(InfoTabView.connectivityStatusRows(identity: identity, connectivity: nil).isEmpty)
        }
        let future = VehicleIdentitySnapshot(availability: .unknown, vin: "TEST", usageMode: "USAGE_MODE_FUTURE")
        #expect(future.usageModeDisplayName == L10n.format("Unrecognised state: %@", "Future"))
    }

    @Test func modeCanBeShownWithoutInventingConnectivity() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = VehicleIdentitySnapshot(availability: .unknown, availabilityReportedAt: date,
                                               vin: "TEST", usageMode: "INACTIVE")
        let rows = InfoTabView.connectivityStatusRows(identity: identity, connectivity: nil)
        #expect(rows.first?.key == L10n.text("Vehicle Mode"))
        #expect(rows.first?.value == L10n.text("Inactive"))
        #expect(!rows.contains { $0.key == L10n.text("Reported Connection") })
        #expect(rows.last?.value == Format.dateTimeFormatter.string(from: date))

        let connection = VehicleConnectivity(state: .disconnected)
        let withConnection = InfoTabView.connectivityStatusRows(identity: identity, connectivity: connection)
        #expect(withConnection.contains { $0.value == L10n.text("Disconnected") })
        #expect(!withConnection.contains { $0.key == L10n.text("Observed") })
    }

    @Test func rendersDecodedTelemetryAtBothWidthsAndAppearances() throws {
        let scoped = ScopedPreferences(label: "decoded-gui-render")
        let identity = VehicleIdentitySnapshot(availability: .unknown, vin: "TEST", usageMode: "INACTIVE")
        let rows = InfoTabView.connectivityStatusRows(identity: identity, connectivity: nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".unlazy/polestar-gui-20261030/renders", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for width in [360, 620] {
            var variants: [Data] = []
            for dark in [false, true] {
                let view = VStack(alignment: .leading, spacing: 16) {
                    CardHeader(symbol: "antenna.radiowaves.left.and.right",
                               title: L10n.text("Connectivity & Wake"), color: HisingenTheme.chartInfo)
                    ForEach(rows.indices, id: \.self) { rows[$0] }
                    Divider()
                    CabinThermalMatrix(driverSeatLevel: nil, passengerSeatLevel: 0,
                                        steeringWheelLevel: 3, interiorTemperatureCelsius: 18,
                                        requestedTemperatureCelsius: 22, activity: .heating)
                }
                .padding(16)
                .frame(width: CGFloat(width))
                .background(HisingenTheme.canvas)
                .environment(\.preferencesStore, scoped.store)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: nil)
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                var image: CGImage?
                appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
                let rendered = try #require(image)
                #expect(rendered.width == width)
                #expect(rendered.height > 160 && rendered.height < 600)
                let bitmap = NSBitmapImageRep(cgImage: rendered)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: root.appendingPathComponent("telemetry-\(width)-\(dark ? "dark" : "light").png"))
                variants.append(data)
            }
            #expect(variants[0] != variants[1])
        }
    }
}
