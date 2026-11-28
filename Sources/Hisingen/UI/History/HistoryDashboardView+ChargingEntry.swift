import SwiftUI

// `HistoryDashboardView` – the charging-session entry sheet. A session recorded by the car has
// no price and a place the car cannot know; this sheet is where a reader logs a public charge
// from a receipt, or corrects the place and price of one the app recorded.

extension HistoryDashboardView {
    var chargingSessionEntrySheet: some View {
        let validation = ManualChargingSessionValidation.validate(
            energyText: sessionEnergyText,
            totalPriceText: sessionTotalPriceText,
            pricePerKwhText: sessionPricePerKwhText
        )
        let datesValid = sessionEndedAt > sessionStartedAt
        // A new session needs its price; editing an old one may only change the place or energy.
        let priceSatisfied = validation.hasPrice || editingChargingSession != nil
        let canSave = validation.isValid && datesValid && priceSatisfied
        return VStack(alignment: .leading, spacing: 12) {
            Text(editingChargingSession == nil
                 ? L10n.text("Log Charging Session")
                 : L10n.text("Edit Charging Session"))
                .hisType(.heading, weight: .semibold)
            DatePicker(L10n.text("Started"), selection: $sessionStartedAt,
                       displayedComponents: [.date, .hourAndMinute])
            DatePicker(L10n.text("Ended"), selection: $sessionEndedAt,
                       displayedComponents: [.date, .hourAndMinute])
            if !datesValid {
                Text(L10n.text("The session must end after it starts."))
                    .hisType(.micro, weight: .semibold)
                    .foregroundStyle(HisingenTheme.semanticCritical)
            }
            Picker(L10n.text("Charging place"), selection: $sessionPlace) {
                ForEach(ChargingSessionPlace.allCases, id: \.self) { place in
                    Text(place.displayName).tag(place)
                }
            }
            .pickerStyle(.segmented)
            LabeledField(title: L10n.text("Location"), text: $sessionLocationText)
            LabeledField(title: L10n.text("Energy (kWh)"), text: $sessionEnergyText,
                         reason: validation.reason(for: .energy))
            LabeledField(title: L10n.text("Total price"), text: $sessionTotalPriceText,
                         reason: validation.reason(for: .totalPrice))
            LabeledField(title: L10n.text("Price per kWh"), text: $sessionPricePerKwhText,
                         reason: validation.reason(for: .pricePerKwh))
            if validation.needsPrice, editingChargingSession == nil {
                Text(L10n.text("Enter a total price or a price per kWh."))
                    .hisType(.micro, weight: .semibold)
                    .foregroundStyle(HisingenTheme.semanticCritical)
            }
            if let total = validation.resolvedTotalCost, datesValid {
                Text(L10n.format("Stored cost: %@", Format.currency(total, symbol: preferences.currencySymbol)))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(L10n.text("Stored with the session and included in the home and public charging totals."))
                .hisType(.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    showChargingSessionSheet = false
                    editingChargingSession = nil
                }
                Button(L10n.text("Save")) { saveChargingSessionEntry() }
                    .buttonStyle(.hisProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    func beginAddingChargingSession() {
        editingChargingSession = nil
        let now = Date()
        sessionStartedAt = now.addingTimeInterval(-1_800)
        sessionEndedAt = now
        sessionLocationText = ""
        sessionEnergyText = ""
        sessionTotalPriceText = ""
        sessionPricePerKwhText = ""
        sessionPlace = .publicCharging
        showChargingSessionSheet = true
    }

    func beginEditingChargingSession(_ session: HistoricalChargingSession) {
        editingChargingSession = session
        sessionStartedAt = session.startedAt
        sessionEndedAt = session.endedAt ?? session.startedAt.addingTimeInterval(1_800)
        sessionLocationText = session.locationName ?? ""
        let entry = chargingEntryText(for: session)
        sessionEnergyText = entry.energy
        sessionTotalPriceText = entry.total
        sessionPricePerKwhText = entry.perKwh
        sessionPlace = session.place
        showChargingSessionSheet = true
    }

    private func saveChargingSessionEntry() {
        let validation = ManualChargingSessionValidation.validate(
            energyText: sessionEnergyText,
            totalPriceText: sessionTotalPriceText,
            pricePerKwhText: sessionPricePerKwhText
        )
        guard validation.isValid, sessionEndedAt > sessionStartedAt,
              validation.hasPrice || editingChargingSession != nil else { return }
        let location = sessionLocationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationName = location.isEmpty ? nil : location
        if let session = editingChargingSession {
            let entry = chargingEntryText(for: session)
            let original = ManualChargingSessionValidation.validate(
                energyText: entry.energy, totalPriceText: entry.total, pricePerKwhText: entry.perKwh
            )
            let priceChanged = validation.totalCost != original.totalCost
                || validation.pricePerKwh != original.pricePerKwh
            history.updateChargingSession(
                id: session.id, vin: state.identity.vin,
                startedAt: sessionStartedAt, endedAt: sessionEndedAt,
                locationName: locationName, place: sessionPlace,
                energyKwh: validation.energyKwh == original.energyKwh ? session.energyDeliveredKwh : validation.energyKwh,
                totalCost: validation.totalCost, pricePerKwh: validation.pricePerKwh, priceChanged: priceChanged
            )
        } else {
            history.addManualChargingSession(
                vin: state.identity.vin,
                startedAt: sessionStartedAt, endedAt: sessionEndedAt,
                locationName: locationName, place: sessionPlace,
                energyKwh: validation.energyKwh,
                totalCost: validation.totalCost, pricePerKwh: validation.pricePerKwh
            )
        }
        showChargingSessionSheet = false
        editingChargingSession = nil
        bumpRefresh()
    }

    private func chargingEntryText(for session: HistoricalChargingSession) -> (energy: String, total: String, perKwh: String) {
        let locale = L10n.displayLocale
        return (
            session.energyDeliveredKwh > 0 ? String(format: "%.2f", locale: locale, session.energyDeliveredKwh) : "",
            session.estimatedCost.map { String(format: "%.2f", locale: locale, $0) } ?? "",
            session.tariffPricePerKwh.map { String(format: "%.4f", locale: locale, $0) } ?? ""
        )
    }
}
