import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One period's report: what the car drove, what that cost at the reader's rate, what was spent on
/// maintenance, and what the ownership assumption says the car lost in value.
///
/// Every figure is loaded from local history through `HistoryWorkspace`, and the same loader feeds
/// the recurring report notification, so the card and the banner cannot disagree. The card is its
/// own view with its own state: History's period picker scopes the charts, while this card steps
/// week by week so a reader can read last month's report without moving every other chart.
@MainActor
struct PeriodReportCard: View {
    let history: HistoryWorkspace
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences

    @State private var cadence: ReportCadence = .monthly
    /// 0 is the window the reader is living in, 1 the one before it.
    @State private var periodsBack = 0
    @State private var report: PeriodReportInput?
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var maintenance: [MaintenanceEntry] = []
    @State private var ownership: VehicleOwnership?
    @State private var showMaintenanceSheet = false
    @State private var showOwnershipSheet = false
    @State private var saveNotice: String?

    var body: some View {
        HistoryCardSurface {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let report {
                    totals(report)
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    depreciation(report)
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    trips(report)
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    maintenanceLog
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    actions(report)
                } else {
                    HisingenEmptyState(
                        symbol: "doc.text",
                        title: L10n.text("No report for this period"),
                        message: L10n.text("Pick another week or month, or drive the car so there is something to report."),
                        actions: { EmptyView() })
                }
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showMaintenanceSheet) { maintenanceSheet }
        .sheet(isPresented: $showOwnershipSheet) { ownershipSheet }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardHeader(symbol: "doc.text", title: L10n.text("Period Report"),
                           color: HisingenTheme.chartAttention)
                Spacer()
                Button {
                    copyReport()
                } label: {
                    Image(systemName: "doc.on.doc").hisType(.label)
                }
                .buttonStyle(.pressable)
                .disabled(report == nil)
                .help(L10n.text("Copy report"))
                .accessibilityLabel(L10n.text("Copy report"))
            }
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { cadence },
                    set: { value in
                        cadence = value
                        periodsBack = 0
                    }
                )) {
                    ForEach(ReportCadence.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180)
                .accessibilityLabel(L10n.text("Report period"))

                Spacer(minLength: 0)

                Button {
                    periodsBack += 1
                } label: {
                    Image(systemName: "chevron.left").hisType(.label)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Earlier period"))
                .accessibilityLabel(L10n.text("Earlier period"))

                Text(selectedPeriod.titleText())
                    .hisType(.caption, weight: .medium)
                    .lineLimit(1)
                    .frame(minWidth: 96)

                Button {
                    periodsBack = max(0, periodsBack - 1)
                } label: {
                    Image(systemName: "chevron.right").hisType(.label)
                }
                .buttonStyle(.pressable)
                .disabled(periodsBack == 0)
                .help(L10n.text("Later period"))
                .accessibilityLabel(L10n.text("Later period"))
            }
            if let saveNotice {
                Text(saveNotice)
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Totals

    private func totals(_ report: PeriodReportInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            figureRow(L10n.text("Distance"),
                      Format.distance(km: report.distanceKm, decimals: 1, unit: report.distanceUnit))
            figureRow(L10n.text("Energy Used"), Format.energyKwh(report.chargingEnergyKwh))
            figureRow(L10n.text("Trips"), Format.count(report.trips.count))
            figureRow(L10n.text("Charges"), Format.count(report.charges.count))
            if report.tripCostCoverage > 0 {
                figureRow(L10n.text("Estimated Trip Cost"),
                          Format.currency(report.tripCost, symbol: report.currencySymbol))
            }
            if report.chargingCostCoverage > 0 {
                figureRow(L10n.text("Charging Cost"),
                          Format.currency(report.chargingCost, symbol: report.currencySymbol))
            }
            if !report.maintenance.isEmpty {
                figureRow(L10n.text("Maintenance"),
                          Format.currency(report.maintenanceCost, symbol: report.currencySymbol))
            }
        }
    }

    private func figureRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).hisType(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).hisType(.label, weight: .semibold).monospacedDigit()
        }
    }

    // MARK: - Depreciation

    private func depreciation(_ report: PeriodReportInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Depreciation")).hisType(.caption, weight: .semibold)
                Spacer()
                Button(L10n.text("Ownership figures")) { showOwnershipSheet = true }
                    .buttonStyle(.pressable)
                    .hisType(.micro)
            }
            if let figure = report.depreciation {
                figureRow(L10n.text("Value at Start"),
                          Format.currency(figure.valueAtStart, symbol: report.currencySymbol, decimals: 0))
                figureRow(L10n.text("Value at End"),
                          Format.currency(figure.valueAtEnd, symbol: report.currencySymbol, decimals: 0))
                figureRow(L10n.text("Loss in Period"),
                          Format.currency(figure.periodLoss, symbol: report.currencySymbol, decimals: 0))
                if let basis = report.depreciationBasis, !basis.isEmpty {
                    Text(basis)
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(Depreciation.emptyHint)
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Trips

    private func trips(_ report: PeriodReportInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Trips")).hisType(.caption, weight: .semibold)
            if report.trips.isEmpty {
                Text(L10n.text("No trips in this period."))
                    .hisType(.micro).foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.trips.prefix(8).enumerated()), id: \.offset) { _, trip in
                    HStack(spacing: 8) {
                        Text(Format.shortDate(date: trip.endedAt))
                            .hisType(.micro).foregroundStyle(.secondary)
                        Text(Format.distance(km: trip.distanceKm, decimals: 1, unit: report.distanceUnit))
                            .hisType(.caption)
                        Spacer(minLength: 6)
                        Text(tripCostText(trip, report: report))
                            .hisType(.caption, weight: .medium)
                            .monospacedDigit()
                    }
                }
                if report.trips.count > 8 {
                    Text(L10n.format("%d more in the exported report", report.trips.count - 8))
                        .hisType(.micro).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A trip with no reported consumption has no honest cost, so it says so rather than printing
    /// a zero that would read as free.
    private func tripCostText(_ trip: PeriodReportTrip, report: PeriodReportInput) -> String {
        guard let cost = trip.cost else { return L10n.text("No consumption reading") }
        let amount = Format.currency(cost, symbol: report.currencySymbol)
        return trip.priceUsedFallback
            ? L10n.format("%@ · fixed rate", amount)
            : amount
    }

    // MARK: - Maintenance log

    private var maintenanceLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Maintenance Log")).hisType(.caption, weight: .semibold)
                Spacer()
                Button(L10n.text("Add entry")) { showMaintenanceSheet = true }
                    .buttonStyle(.pressable)
                    .hisType(.micro)
            }
            let entries = maintenance.filter { selectedPeriod.contains($0.date) }
            if entries.isEmpty {
                Text(L10n.text("No maintenance entries in this period."))
                    .hisType(.micro).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(Format.shortDate(date: entry.date))
                            .hisType(.micro).foregroundStyle(.secondary)
                        Text(entry.kind.title).hisType(.micro).foregroundStyle(.secondary)
                        Text(entry.title).hisType(.caption).lineLimit(1)
                        Spacer(minLength: 6)
                        if let cost = entry.cost {
                            Text(Format.currency(cost, symbol: preferences.currencySymbol))
                                .hisType(.caption, weight: .medium).monospacedDigit()
                        }
                        Button {
                            history.deleteMaintenanceEntry(id: entry.id, vin: state.identity.vin)
                            reloadMaintenance()
                            loadGeneration &+= 1
                        } label: {
                            Image(systemName: "trash").hisType(.micro)
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                        .buttonStyle(.pressable)
                        .help(L10n.text("Delete"))
                        .accessibilityLabel(L10n.text("Delete"))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func actions(_ report: PeriodReportInput) -> some View {
        HStack(spacing: 10) {
            Button(L10n.text("Copy")) { copyReport() }
                .buttonStyle(.pressable)
                .hisType(.micro)
            Button(L10n.text("Export…")) { export(report) }
                .buttonStyle(.pressable)
                .hisType(.micro)
            Spacer(minLength: 0)
        }
    }

    private func copyReport() {
        guard let report else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(VehiclePeriodReport.text(report), forType: .string)
        announce(L10n.text("Report copied"))
    }

    private func export(_ report: PeriodReportInput) {
        FileExport.save(
            VehiclePeriodReport.text(report), type: .plainText,
            filename: VehiclePeriodReport.fileName(report)
        ) { url, error in
            if error != nil {
                announce(L10n.text("The report could not be saved."))
            } else {
                announce(L10n.format("Report saved to %@", url.lastPathComponent))
            }
        }
    }

    private func announce(_ text: String) {
        saveNotice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if saveNotice == text { saveNotice = nil }
        }
    }

    // MARK: - Sheets

    @State private var entryKind: MaintenanceKind = .service
    @State private var entryDate = Date()
    @State private var entryTitle = ""
    @State private var entryCost = ""
    @State private var entryOdometer = ""
    @State private var entryNotes = ""

    private var maintenanceSheet: some View {
        let validation = MaintenanceEntryValidation.validate(
            title: entryTitle, costText: entryCost, odometerText: entryOdometer)
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Add Maintenance Entry")).hisType(.heading, weight: .semibold)
            Picker(L10n.text("Kind"), selection: $entryKind) {
                ForEach(MaintenanceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .controlSize(.small)
            DatePicker(L10n.text("Date"), selection: $entryDate, displayedComponents: .date)
                .controlSize(.small)
            HistoryDashboardView.LabeledField(
                title: L10n.text("What was done"), text: $entryTitle,
                reason: validation.reason(for: .title))
            HistoryDashboardView.LabeledField(
                title: L10n.text("Cost, optional"), text: $entryCost,
                reason: validation.reason(for: .cost))
            HistoryDashboardView.LabeledField(
                title: L10n.text("Odometer (km), optional"), text: $entryOdometer,
                reason: validation.reason(for: .odometer))
            HistoryDashboardView.LabeledField(
                title: L10n.text("Notes, optional"), text: $entryNotes)
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { showMaintenanceSheet = false }
                Button(L10n.text("Save")) {
                    saveEntry(validation)
                }
                .buttonStyle(.hisProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid)
            }
            Text(L10n.text("Maintenance entries stay on this Mac and appear in the period report."))
                .hisType(.micro).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func saveEntry(_ validation: MaintenanceEntryValidation) {
        guard validation.isValid else { return }
        let entry = MaintenanceEntry(
            vin: state.identity.vin, date: entryDate, odometerKm: validation.odometerKm,
            kind: entryKind, title: validation.title, notes: entryNotes, cost: validation.cost)
        guard history.addMaintenanceEntry(entry) != nil else {
            announce(L10n.text("The entry could not be saved."))
            return
        }
        entryTitle = ""; entryCost = ""; entryOdometer = ""; entryNotes = ""
        showMaintenanceSheet = false
        reloadMaintenance()
        loadGeneration &+= 1
        announce(L10n.text("Maintenance entry saved"))
    }

    @State private var purchasePrice = ""
    @State private var purchaseDate = Date()
    @State private var annualDecline = "15"

    private var ownershipSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Ownership Figures")).hisType(.heading, weight: .semibold)
            Text(Depreciation.emptyHint)
                .hisType(.micro).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HistoryDashboardView.LabeledField(
                title: L10n.text("Purchase price"), text: $purchasePrice)
            DatePicker(L10n.text("Purchase date"), selection: $purchaseDate,
                       in: ...Date(), displayedComponents: .date)
                .controlSize(.small)
            HistoryDashboardView.LabeledField(
                title: L10n.text("Annual value decline (%)"), text: $annualDecline)
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { showOwnershipSheet = false }
                Button(L10n.text("Save")) { saveOwnership() }
                    .buttonStyle(.hisProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ownershipInputIsValid)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var ownershipInputIsValid: Bool {
        guard let price = number(purchasePrice), price > 0,
              let decline = number(annualDecline), decline > 0,
              decline <= DepreciationAssumption.maximumAnnualDeclinePercent else { return false }
        return true
    }

    private func saveOwnership() {
        guard let price = number(purchasePrice), let decline = number(annualDecline) else { return }
        let ownership = VehicleOwnership(
            vin: state.identity.vin,
            assumption: DepreciationAssumption(
                purchasePrice: price, purchaseDate: purchaseDate,
                annualDeclinePercent: decline))
        guard history.saveOwnership(ownership) else {
            announce(L10n.text("The ownership figures could not be saved."))
            return
        }
        self.ownership = ownership
        showOwnershipSheet = false
        loadGeneration &+= 1
        announce(L10n.text("Ownership figures saved"))
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Loading

    /// Which window is on screen. `periodsBack` steps the selected window backwards, so "0" is the
    /// window the reader is living in.
    private var selectedPeriod: ReportPeriod {
        var period = cadence.period(containing: Date())
        for _ in 0..<periodsBack {
            period = cadence.completedPeriod(endingAt: period.start)
        }
        return period
    }

    private var loadKey: String {
        "\(cadence.rawValue)|\(periodsBack)|\(loadGeneration)|\(state.identity.vin)"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        reloadMaintenance()
        ownership = history.ownership(for: state.identity.vin)
        if let ownership {
            purchasePrice = Format.number(ownership.assumption.purchasePrice, decimals: 0)
            purchaseDate = ownership.assumption.purchaseDate
            annualDecline = Format.number(ownership.assumption.annualDeclinePercent, decimals: 0)
        }
        let period = selectedPeriod
        let name = preferences.formattedVehicleTitle(
            vin: state.identity.vin,
            modelName: state.identity.modelName,
            modelYear: state.identity.modelYear,
            registrationNo: state.identity.registrationNo)
        let loaded = await history.periodReport(
            vin: state.identity.vin, vehicleName: name, period: period,
            redacted: preferences.privacyRedactionEnabled)
        guard !Task.isCancelled else { return }
        report = loaded.isEmpty ? nil : loaded
    }

    private func reloadMaintenance() {
        maintenance = history.maintenanceEntries(for: state.identity.vin)
    }
}
