import SwiftUI

/// Settings, Electricity: what the grid company charges per kWh on top of Tibber's price. Optional. It
/// shows only with Tibber connected, because Tibber's price is the one that leaves the grid fee out.
///
/// The tariff can be a flat fee, Vattenfall Eldistribution's 2026 single or time tariff, or a custom
/// time-of-use schedule. Every figure the app shows with a grid fee reads this one tariff.
@MainActor
struct SettingsGridTariffCard: View {
    @ObservedObject var model: HomeChargingModel
    var onOpenSupplier: (() -> Void)? = nil

    @State private var flatText = ""
    @State private var peakText = ""
    @State private var offPeakText = ""
    @State private var startText = ""
    @State private var endText = ""
    @State private var fixedText = ""
    @State private var comparison: TariffComparison?

    private var tariff: GridTariff { model.gridTariff }

    var body: some View {
        if model.tibberHome != nil {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "bolt.horizontal", title: L10n.text("Grid Tariff"), color: HisingenTheme.semanticWarning)
                    Text(L10n.text("Optional. What your grid company charges per kWh on top of Tibber's price. The planner, charger sessions and the house-load costs use it."))
                        .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                    regionPicker
                    if let suggested = suggestedRegion { regionOffer(suggested) }
                    if !tariff.region.hasPublishedRates { noRatesNotice }
                    kindPicker
                    if tariff.isPreset { presetRows }
                    if tariff.isPreset, !tariff.belongsToGridCompany(model.tibberHome?.gridCompany) { operatorNotice }
                    if tariff.kind == .flat { flatRow }
                    if tariff.kind == .custom { customRows }
                    if tariff.kind != .none { fixedFeeRow }
                    if tariff.hasFee { nowRow }
                    if tariff.isStale() { staleNotice }
                    if tariff.isPreset { comparisonRows }
                }
            }
            .onAppear(perform: loadFields)
            .task(id: comparisonKey) { await loadComparison() }
        } else if let onOpenSupplier {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "bolt.horizontal", title: L10n.text("Grid Tariff"), color: HisingenTheme.semanticWarning)
                    NavigationRow(title: L10n.text("Electricity Supplier"), action: onOpenSupplier)
                }
            }
        }
    }

    private var comparisonKey: String { "\(tariff.region.rawValue)/\(tariff.kind.rawValue)" }

    // MARK: Units

    private var isSwedishMarket: Bool { tariff.region == .sweden }

    /// The hundredth of a currency unit this market prints on its invoice. Sweden keeps the wording
    /// the app already ships in every language, because it is the market with published rates.
    private var feeUnitWord: String { tariff.region.feeUnitWord }

    // MARK: Country

    private var regionPicker: some View {
        HStack {
            Text(L10n.text("Grid Tariff Country")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
            Spacer(minLength: 8)
            Picker("", selection: regionBinding) {
                ForEach(GridTariffRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Grid Tariff Country"))
            .controlSize(.small)
            .frame(maxWidth: 200)
        }
    }

    private var regionBinding: Binding<GridTariffRegion> {
        Binding(get: { tariff.region }, set: { chooseRegion($0) })
    }

    private func chooseRegion(_ region: GridTariffRegion) {
        guard region != tariff.region else { return }
        model.updateGridTariff(tariff.moved(to: region))
        loadFields()
    }

    /// The fuse the reader picked, else the one Tibber reports for the home, else the usual default.
    private var defaultFuseAmps: Int {
        tariff.fuseAmps ?? model.tibberHome?.mainFuseSize ?? 25
    }

    /// A preset is one company's price list. Applying it to another operator's meter is a wrong
    /// number in every cost the app shows, so it says so instead of staying quiet.
    private var operatorNotice: some View {
        Text(L10n.format("These prices are %@'s, but your grid company is %@. Check them against your invoice, or enter your own as a custom tariff.",
                         tariff.presetOperatorName ?? "", model.tibberHome?.gridCompany ?? ""))
            .hisType(.label).foregroundStyle(HisingenTheme.ink)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hisNotice(HisingenTheme.semanticWarning)
    }

    /// The market the connected Tibber home sits in, when it differs from the one the tariff is
    /// priced in. Tibber reports the home's time zone, so this needs no answer from the reader.
    private var suggestedRegion: GridTariffRegion? {
        guard let region = GridTariffRegion.matching(timeZoneIdentifier: model.tibberHome?.timeZone),
              region != tariff.region else { return nil }
        return region
    }

    /// Offered rather than applied: crossing a border clears the rates, so the reader asks for it.
    private func regionOffer(_ region: GridTariffRegion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .hisType(.caption)
                .foregroundStyle(HisingenTheme.accent)
            Text(L10n.format("Tibber puts this home in %@", region.displayName))
                .hisType(.caption)
                .foregroundStyle(HisingenTheme.inkMuted)
            Button(L10n.text("Use")) {
                guard region != tariff.region else { return }
                model.updateGridTariff(tariff.moved(to: region))
                loadFields()
            }
            .buttonStyle(.pressable)
            .controlSize(.small)
            .accessibilityLabel(L10n.format("Use %@", region.displayName))
        }
    }

    private var noRatesNotice: some View {
        Text(L10n.format("No published grid rates for %@ in this build. Copy the fee from your invoice and enter it as a custom tariff.",
                         tariff.region.displayName))
            .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hisNotice(HisingenTheme.inkMuted)
    }

    // MARK: Kind

    private var kindBinding: Binding<GridTariff.Kind> {
        Binding(get: { tariff.kind }, set: { choose($0) })
    }

    private var kindPicker: some View {
        HStack {
            Text(L10n.text("Tariff")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
            Spacer(minLength: 8)
            Picker("", selection: kindBinding) {
                Text(L10n.text("No grid fee")).tag(GridTariff.Kind.none)
                Text(L10n.text("Flat fee")).tag(GridTariff.Kind.flat)
                // Each market gets only the preset whose published rates belong to it. Norway is
                // the one market beyond Sweden the tariff model can express; Denmark needs three
                // periods, Germany has no national tariff and the Netherlands bills capacity.
                switch tariff.region {
                case .sweden:
                    Text(L10n.text("Vattenfall single tariff (E4)")).tag(GridTariff.Kind.vattenfallSingle)
                    Text(L10n.text("Vattenfall time tariff (T4)")).tag(GridTariff.Kind.vattenfallTime)
                case .norway:
                    Text(L10n.text("Elvia day and night tariff")).tag(GridTariff.Kind.elviaNorway)
                case .denmark, .germany, .netherlands:
                    EmptyView()
                }
                Text(L10n.text("Custom time-of-use")).tag(GridTariff.Kind.custom)
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Grid tariff"))
            .controlSize(.small)
            .frame(maxWidth: 260)
        }
    }

    private func choose(_ kind: GridTariff.Kind) {
        guard kind != tariff.kind else { return }
        let current = tariff
        var next: GridTariff
        switch kind {
        case .none:
            next = .none
        case .flat:
            next = .flat(orePerKwh: current.offPeakOrePerKwh)
            next.kind = .flat
            // Switching here used to zero the fixed fee the field row keeps, so a flat tariff lost
            // the yearly figure the moment it was chosen.
            next.fixedKrPerYear = current.fixedKrPerYear
        case .vattenfallSingle, .vattenfallTime:
            next = .vattenfall(kind, fuseAmps: current.fuseAmps ?? defaultFuseAmps)
        case .elviaNorway:
            // The Norwegian preset carries its own market, unlike the Swedish factories, so the
            // region is not put back over it below.
            next = .elvia()
            model.updateGridTariff(next)
            loadFields()
            return
        case .custom:
            next = current
            next.kind = .custom
            next.priceYear = nil
            if !current.isTimeVarying {
                // Start from what is shown, so switching to custom never loses the rate already entered.
                next.peakMonths = GridTariff.winterMonths
                next.peakStartHour = 6
                next.peakEndHour = 22
                next.peakWeekdaysOnly = true
            }
        }
        // The Swedish factories build a Swedish tariff, so the market is put back over the top.
        // Elvia returned above with its own market.
        next.region = current.region
        model.updateGridTariff(next)
        loadFields()
    }

    // MARK: Presets

    private var presetRows: some View {
        VStack(spacing: 4) {
            if let year = tariff.priceYear {
                KVRow(L10n.text("Prices"), L10n.format("From %d, VAT included", year))
            }
            KVRow(tariff.isTimeVarying ? L10n.text("High-load time") : L10n.text("Transfer fee"),
                  L10n.format("%@ öre/kWh", Format.number(tariff.peakOrePerKwh, decimals: 1)))
            if tariff.isTimeVarying {
                KVRow(L10n.text("Other time"), L10n.format("%@ öre/kWh", Format.number(tariff.offPeakOrePerKwh, decimals: 1)))
            }
            HStack {
                Text(L10n.text("Main fuse")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Spacer(minLength: 8)
                Picker("", selection: fuseBinding) {
                    ForEach(GridTariff.vattenfallFuseSizes, id: \.self) { Text(Format.amps($0)).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Main fuse"))
                .controlSize(.small)
                .frame(maxWidth: 100)
            }
        }
    }

    private var fuseBinding: Binding<Int> {
        Binding(get: { defaultFuseAmps }, set: { amps in
            var next = GridTariff.vattenfall(tariff.kind, fuseAmps: amps)
            next.region = tariff.region
            model.updateGridTariff(next)
            loadFields()
        })
    }

    // MARK: Flat and custom

    private var flatRow: some View {
        fieldRow(L10n.text("Fee, öre per kWh"), text: $flatText) { value in
            var next = GridTariff.flat(orePerKwh: value)
            next.kind = .flat
            next.fixedKrPerYear = tariff.fixedKrPerYear
            model.updateGridTariff(next)
        }
    }

    private var customRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldRow(highLoadFeeTitle, text: $peakText) { value in update { $0.peakOrePerKwh = value } }
            fieldRow(otherTimeFeeTitle, text: $offPeakText) { value in update { $0.offPeakOrePerKwh = value } }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("High-load hours")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Spacer(minLength: 8)
                hourField($startText, label: L10n.text("High-load starts at hour")) { hour in
                    guard (0...23).contains(hour), hour < tariff.peakEndHour else { return }
                    update { $0.peakStartHour = hour }
                }
                Text("–").hisType(.body).foregroundStyle(HisingenTheme.inkMuted)
                hourField($endText, label: L10n.text("High-load ends at hour")) { hour in
                    guard (1...24).contains(hour), hour > tariff.peakStartHour else { return }
                    update { $0.peakEndHour = hour }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("High-load months")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                monthChips
            }
            Toggle(isOn: Binding(get: { tariff.peakWeekdaysOnly }, set: { value in update { $0.peakWeekdaysOnly = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Weekdays only")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                    Text(L10n.text("The public holidays Swedish grid companies name, such as Christmas Eve and Good Friday, are not high-load."))
                        .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var monthChips: some View {
        let symbols = monthSymbols
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 36), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
            ForEach(1...12, id: \.self) { month in
                let selected = tariff.peakMonths.contains(month)
                Button {
                    update { value in
                        if selected { value.peakMonths.remove(month) } else { value.peakMonths.insert(month) }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(symbols[month - 1]).hisType(.label, weight: selected ? .semibold : .regular)
                            .foregroundStyle(selected ? HisingenTheme.ink : HisingenTheme.inkMuted)
                        Rectangle().fill(selected ? HisingenTheme.ink : Color.clear).frame(height: 2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(symbols[month - 1])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var monthSymbols: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.displayLocale
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = L10n.displayLocale
        return formatter.shortStandaloneMonthSymbols ?? (1...12).map(String.init)
    }

    // MARK: Fixed fee, now, notices

    private var fixedFeeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldRow(isSwedishMarket
                     ? L10n.text("Fixed fee, kr per year")
                     : L10n.format("Fixed fee, %@ per year", tariff.region.currencySymbol),
                     text: $fixedText) { value in
                update { $0.fixedKrPerYear = value > 0 ? value : nil }
            }
            if let fixed = tariff.fixedKrPerYear {
                let amount = Format.number(fixed / 12, decimals: 0)
                Text(isSwedishMarket
                     ? L10n.format("About %@ kr a month. For reference only, it is in no per-kWh figure.", amount)
                     : L10n.format("About %@ %@ a month. For reference only, it is in no per-kWh figure.",
                                   amount, tariff.region.currencySymbol))
                    .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The fee in force this minute, so a wrong window or month shows up straight away.
    private var nowRow: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            KVRow(L10n.text("Right now"), nowText(at: context.date))
        }
    }

    private func nowText(at date: Date) -> String {
        let fee = Format.number(tariff.feePerKwh(at: date) * 100, decimals: 1)
        guard tariff.isTimeVarying, let next = tariff.nextChange(after: date) else {
            return isSwedishMarket
                ? L10n.format("%@ öre/kWh", fee)
                : L10n.format("%@ %@/kWh", fee, feeUnitWord)
        }
        let calendar = tariff.region.calendar
        let when = calendar.isDate(next, inSameDayAs: date)
            ? Format.shortTime(date: next)
            : "\(Format.shortDate(date: next)) \(Format.shortTime(date: next))"
        guard isSwedishMarket else {
            return tariff.isPeak(at: date)
                ? L10n.format("%@ %@/kWh, high-load until %@", fee, feeUnitWord, when)
                : L10n.format("%@ %@/kWh, other time until %@", fee, feeUnitWord, when)
        }
        return tariff.isPeak(at: date)
            ? L10n.format("%@ öre/kWh, high-load until %@", fee, when)
            : L10n.format("%@ öre/kWh, other time until %@", fee, when)
    }

    private var staleNotice: some View {
        Text(L10n.format("These prices are from %d. Grid companies change them each January, so check your invoice.",
                         tariff.priceYear ?? 0))
            .hisType(.label).foregroundStyle(HisingenTheme.ink)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hisNotice(HisingenTheme.semanticWarning)
    }

    // MARK: Comparison

    @ViewBuilder
    private var comparisonRows: some View {
        if let comparison {
            PanelRule()
            VStack(spacing: 4) {
                KVRow(L10n.format("Single tariff, last %d days", comparison.days), Format.currency(comparison.singleSek, symbol: tariff.region.currencySymbol, decimals: 0),
                      info: L10n.text("Transfer fees only, worked out on your own hourly readings from Tibber."))
                KVRow(L10n.format("Time tariff, last %d days", comparison.days), Format.currency(comparison.timeSek, symbol: tariff.region.currencySymbol, decimals: 0))
            }
            Text(comparisonNote(comparison))
                .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comparisonNote(_ value: TariffComparison) -> String {
        let single = GridTariff.vattenfall(.vattenfallSingle)
        let time = GridTariff.vattenfall(.vattenfallTime)
        let spread = time.peakOrePerKwh - time.offPeakOrePerKwh
        let breakEven = spread > 0 ? (single.offPeakOrePerKwh - time.offPeakOrePerKwh) / spread : 0
        return L10n.format("%d%% of your energy fell in high-load time. The time tariff costs less below %d%%, and is always cheaper outside November to March. A change applies for at least a year, so look at a full year first.",
                           Int((value.highLoadShare * 100).rounded()), Int((breakEven * 100).rounded()))
    }

    private func loadComparison() async {
        guard tariff.isPreset else { comparison = nil; return }
        let to = Date()
        let from = to.addingTimeInterval(-31 * 86_400)
        guard let hours = await model.houseConsumption(from: from, to: to) else { comparison = nil; return }
        comparison = TariffAdvisor.compare(hours: hours, single: .vattenfall(.vattenfallSingle, fuseAmps: defaultFuseAmps),
                                           time: .vattenfall(.vattenfallTime, fuseAmps: defaultFuseAmps))
    }

    // MARK: Field plumbing

    private func fieldRow(_ title: String, text: Binding<String>, commit: @escaping (Double) -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
            Spacer(minLength: 8)
            TextField("", text: text)
                .hisField().frame(width: 90).multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
                .onChange(of: text.wrappedValue) { _, value in
                    let cleaned = value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                    if cleaned.isEmpty { commit(0); return }
                    if let number = Double(cleaned), number.isFinite, number >= 0 { commit(number) }
                }
        }
    }

    private func hourField(_ text: Binding<String>, label: String, commit: @escaping (Int) -> Void) -> some View {
        TextField("", text: text)
            .hisField().frame(width: 52).multilineTextAlignment(.trailing)
            .accessibilityLabel(label)
            .onChange(of: text.wrappedValue) { _, value in
                if let hour = Int(value.trimmingCharacters(in: .whitespaces)) { commit(hour) }
            }
    }

    private var highLoadFeeTitle: String {
        isSwedishMarket
            ? L10n.text("High-load fee, öre per kWh")
            : L10n.format("High-load fee, %@ per kWh", feeUnitWord)
    }

    private var otherTimeFeeTitle: String {
        isSwedishMarket
            ? L10n.text("Other time fee, öre per kWh")
            : L10n.format("Other time fee, %@ per kWh", feeUnitWord)
    }

    private func update(_ change: (inout GridTariff) -> Void) {
        var next = tariff
        change(&next)
        model.updateGridTariff(next)
    }

    /// A Vattenfall preset belongs to Sweden. A stored tariff that says otherwise — a restore from an
    /// older build, say — would show neither the preset rows nor the custom fields, so it is written
    /// back as the reader's own figures instead of becoming a dead end.
    private func normalizeRegion() {
        let normalized = tariff.normalizedForMarket
        guard normalized != tariff else { return }
        model.updateGridTariff(normalized)
    }

    private func loadFields() {
        normalizeRegion()
        func text(_ value: Double) -> String { value == 0 ? "" : String(format: "%g", locale: L10n.displayLocale, value) }
        flatText = text(tariff.offPeakOrePerKwh)
        peakText = text(tariff.peakOrePerKwh)
        offPeakText = text(tariff.offPeakOrePerKwh)
        startText = String(tariff.peakStartHour)
        endText = String(tariff.peakEndHour)
        fixedText = text(tariff.fixedKrPerYear ?? 0)
    }
}
