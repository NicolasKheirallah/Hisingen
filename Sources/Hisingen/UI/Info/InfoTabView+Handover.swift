import AppKit
import SwiftUI

extension InfoTabView {
    /// Writes the handover folder for a sale or trade. The save panel's checkbox is the only way
    /// the VIN, registration and serials reach the folder, and screenshot privacy overrides it.
    func exportHandoverPack() {
        let redacting = preferences.privacyRedactionEnabled
        let includeCheckbox = NSButton(
            checkboxWithTitle: L10n.text("Include VIN and registration"),
            target: nil,
            action: nil
        )
        includeCheckbox.state = redacting ? .off : .on
        includeCheckbox.isEnabled = !redacting

        let hint = NSTextField(wrappingLabelWithString: redacting
            ? L10n.text("Screenshot privacy is on, so the VIN and registration stay out of this pack. Turn it off in Appearance settings to include them.")
            : L10n.text("A buyer usually needs the VIN and registration. Untick this to leave them out."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 340

        let accessory = NSStackView(views: [includeCheckbox, hint])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        accessory.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        accessory.setFrameSize(accessory.fittingSize)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Export")
        panel.message = L10n.text("Choose where to create the handover folder.")
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let includesIdentifiers = !redacting && includeCheckbox.state == .on
        let vin = state.identity.vin
        Task { @MainActor in
            let sessions = await history.persistentChargingSessions(vin: vin, state: state)
            let trips = await history.tripHistory(vin: vin)
            let pack = HandoverPackBuilder.build(
                handoverInput(sessions: sessions, trips: trips, includesIdentifiers: includesIdentifiers)
            )
            do {
                try Self.writeHandoverPack(pack, into: destination)
            } catch {
                reportError = L10n.format("Could not write %@: %@", pack.folderName, error.localizedDescription)
            }
        }
    }

    private func handoverInput(
        sessions: [ChargingSession],
        trips: [TripHistoryEntry],
        includesIdentifiers: Bool
    ) -> HandoverPackInput {
        let identity = state.identity
        let equipment = state.otaCapabilities?.equipment
        // The battery serial is listed as an equipment detail; it is taken out here so the
        // identifier gate in the builder is the only place it can come back in.
        let details = (equipment?.details ?? []).filter { $0.title != "Battery Pack Serial" }
        return HandoverPackInput(
            modelName: identity.modelName,
            modelYear: identity.modelYear,
            vin: identity.vin,
            registrationNo: identity.registrationNo,
            internalVehicleIdentifier: identity.internalVehicleIdentifier,
            pno34: identity.pno34,
            buildWeek: state.formattedBuildWeek ?? identity.structureWeek,
            exteriorPaint: identity.externalColour,
            upholstery: identity.upholstery,
            market: state.otaCapabilities?.identity?.market ?? identity.accountMarket,
            batterySerial: equipment?.batterySerial,
            equipment: details.map { HandoverPackInput.Field(title: $0.title, value: $0.value) },
            includesIdentifiers: includesIdentifiers,
            odometerKm: state.maintenance.odometerKm,
            distanceUnit: preferences.distanceUnit,
            batteryEstimate: batteryHealthEstimate,
            service: state.maintenance.service,
            chargingSessions: sessions,
            trips: trips,
            lastReadingAt: state.dataTimestamp,
            generatedAt: Date()
        )
    }

    /// Creates the pack folder inside the chosen destination. An existing folder of the same name
    /// is never overwritten; the new one gets a numeric suffix instead.
    private static func writeHandoverPack(_ pack: HandoverPack, into destination: URL) throws {
        let fileManager = FileManager.default
        var folder = destination.appendingPathComponent(pack.folderName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: folder.path) {
            folder = destination.appendingPathComponent("\(pack.folderName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for file in pack.files {
                try file.contents.write(to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
            }
        } catch {
            // A half-written folder would look like a complete handover. Remove it and report.
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }
}
