import SwiftUI

/// Sets, previews, updates, holds and cancels the plan Home Assistant runs for the paired charger.
///
/// The plan lives in Home Assistant. This view only describes it: the target, the deadline as an
/// absolute instant shown in the home's time zone, and what Home Assistant says it will do.
@MainActor
struct HomeChargingPlanEditor: View {
    let state: VehicleState
    @ObservedObject var model: HomeChargingModel

    @Environment(\.preferencesStore) private var preferences
    @State private var kind: HomePlanTargetKind = .addKwh
    @State private var kwh: Double = 10
    @State private var percent: Double = 80
    @State private var deadline = Date()
    @State private var didSeed = false
    @State private var preview: HomeChargingPlanStatus?
    @State private var previewProblem: String?
    @State private var isBusy = false
    @State private var problem: String?
    @State private var automations: [String] = []
    @State private var confirmsCancel = false

    private var pairing: HomeChargingPairing? { model.pairing }
    private var zone: TimeZone { pairing?.timeZone ?? .current }
    private var activePlan: HomeChargingPlanStatus? { model.planStatus.flatMap { $0.phase.isTerminal ? nil : $0 } }
    private var capacityKwh: Double {
        state.configuredCapacityReference(specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)).kwh
    }
    /// The car's own charge limit is the ceiling: Home Assistant never plans past it.
    private var percentCeiling: Double { Double(state.energy.targetPercentage ?? 100) }
    private var energyCeiling: Double { max(5, (capacityKwh * ChargingPlannerSupport.chargingLossFactor).rounded()) }
    private var canSubmit: Bool {
        guard !isBusy, model.componentInstalled != false, model.link == .live else { return false }
        return kind == .addKwh || model.capabilities.supportsReachPercent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Run in Home Assistant"))
                .hisType(.subhead, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
            Text(L10n.text("Home Assistant keeps the plan and runs it when this Mac sleeps or Hisingen is closed."))
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if model.componentInstalled == false { componentMissing }
            if let plan = activePlan { currentPlan(plan) }

            targetSection
            deadlineSection
            supportedSection
            previewSection
            conflictsSection
            if let problem {
                Text(problem)
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.ink)
                    .padding(9)
                    .hisNotice(HisingenTheme.semanticCritical)
            }
            actions
        }
        .onAppear(perform: seedIfNeeded)
        .task(id: previewKey) { await refreshPreview() }
        .task { automations = await model.automationsUsingCharger() }
        .confirmationDialog(L10n.text("Cancel the plan?"), isPresented: $confirmsCancel, titleVisibility: .visible) {
            Button(L10n.text("Cancel Plan"), role: .destructive) { run { try await model.cancelPlan() } }
            Button(L10n.text("Keep Plan"), role: .cancel) {}
        } message: {
            Text(L10n.text("Home Assistant stops the plan and leaves the charger as it is."))
        }
    }

    // MARK: - Sections

    private var componentMissing: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("The Hisingen component is not installed in Home Assistant"))
                .hisType(.body, weight: .medium)
                .foregroundStyle(HisingenTheme.ink)
            Text(L10n.text("Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps."))
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .hisNotice(HisingenTheme.semanticWarning)
    }

    private func currentPlan(_ plan: HomeChargingPlanStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KVRow(L10n.text("Plan"), phaseText(plan.phase))
            if let target = plan.target, let deadline = plan.deadline {
                KVRow(L10n.text("Target"), L10n.format("%@ by %@", target.summary, HomeChargingTime.deadline(deadline, in: zone, now: model.clock)))
            }
            KVRow(L10n.text("Delivered"), Format.energyKwh(plan.deliveredKwh))
            if let remaining = plan.remainingKwh {
                KVRow(L10n.text("Remaining"), Format.energyKwh(remaining))
            }
            if let rate = plan.rateKw {
                KVRow(L10n.text("Planning rate"), Format.powerKw(rate),
                      info: L10n.text("Measured from recent charger sessions. It updates when the car charges slower than planned."))
            }
            ForEach(plan.warnings, id: \.self) { code in
                Text(plan.warningText(code)).hisType(.label).foregroundStyle(HisingenTheme.semanticWarning)
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            UnderlineSegments(
                options: [(HomePlanTargetKind.addKwh, L10n.text("Add energy")), (HomePlanTargetKind.reachPercent, L10n.text("Reach a percentage"))],
                selection: $kind, accessibilityLabel: L10n.text("Plan target type"))
            switch kind {
            case .addKwh:
                HStack {
                    Text(L10n.text("Add")).hisType(.body).foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(Format.energyKwh(kwh))
                        .hisType(.displaySmall).monospacedDigit().foregroundStyle(HisingenTheme.ink)
                }
                Slider(value: $kwh, in: 1...energyCeiling, step: 0.5)
                    .tint(HisingenTheme.accent)
                    .accessibilityLabel(L10n.text("Energy to add"))
                    .accessibilityValue(Format.energyKwh(kwh))
                Text(L10n.text("Measured at the charger, so it includes charging losses."))
                    .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
            case .reachPercent:
                HStack {
                    Text(L10n.text("Reach")).hisType(.body).foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(Format.percent(percent))
                        .hisType(.displaySmall).monospacedDigit().foregroundStyle(HisingenTheme.ink)
                }
                Slider(value: $percent, in: 10...max(15, percentCeiling), step: 5)
                    .tint(HisingenTheme.accent)
                    .disabled(!model.capabilities.supportsReachPercent)
                    .accessibilityLabel(L10n.text("Battery percentage to reach"))
                    .accessibilityValue(Format.percent(percent))
                Text(L10n.format("The car's own charge limit of %@ is the ceiling.", Format.percent(percentCeiling)))
                    .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
            }
        }
    }

    private var deadlineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            DatePicker(L10n.text("Ready by"), selection: $deadline, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, zone)
                .hisType(.body)
            Text(L10n.format("Shown in home time, %@.", zone.localizedName(for: .standard, locale: L10n.displayLocale) ?? zone.identifier))
                .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
        }
    }

    private var supportedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("Supported targets"))
                .hisType(.label, weight: .semibold).foregroundStyle(HisingenTheme.inkMuted)
            Text(L10n.text("Add energy: supported."))
                .hisType(.label).foregroundStyle(HisingenTheme.ink)
            if model.capabilities.supportsReachPercent {
                Text(L10n.text("Reach a percentage: supported, from a battery sensor in Home Assistant that updated recently."))
                    .hisType(.label).foregroundStyle(HisingenTheme.ink)
            } else if let why = model.capabilities.reachPercentExplanation {
                Text(why).hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var previewSection: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("What Home Assistant would do"))
                    .hisType(.label, weight: .semibold).foregroundStyle(HisingenTheme.inkMuted)
                if preview.windows.isEmpty {
                    Text(L10n.text("No charging window found before the deadline."))
                        .hisType(.label).foregroundStyle(HisingenTheme.semanticWarning)
                }
                ForEach(Array(preview.windows.enumerated()), id: \.offset) { _, window in
                    KVRow(L10n.text("Window"), HomeChargingTime.window(window.start, window.end, in: zone, now: model.clock),
                          info: window.averagePricePerKwh.map { L10n.format("Average price %@ per kWh from Tibber.", Format.currency($0, symbol: preview.currency ?? preferences.currencySymbol)) })
                }
                if let cost = preview.estimatedCost {
                    KVRow(L10n.text("Estimated electricity cost"), Format.currency(cost, symbol: preview.currency ?? preferences.currencySymbol),
                          info: preview.priceSource.map { L10n.format("Price source: %@.", $0) })
                }
                if let finish = preview.expectedFinish {
                    KVRow(L10n.text("Ready about"), HomeChargingTime.deadline(finish, in: zone, now: model.clock))
                }
                if preview.phase == .unlikely {
                    Text(L10n.text("The target is unlikely by the deadline at the measured charging rate."))
                        .hisType(.label).foregroundStyle(HisingenTheme.semanticWarning)
                }
                ForEach(preview.warnings, id: \.self) { code in
                    Text(preview.warningText(code)).hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
                }
            }
        } else if let previewProblem {
            Text(previewProblem).hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
        }
    }

    @ViewBuilder
    private var conflictsSection: some View {
        let conflicts = HomeChargingConflicts.evaluate(
            vehicle: state.energy, pairing: pairing ?? NexBlueSetupFallback.pairing, telemetry: model.telemetry,
            now: model.clock, automations: automations)
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Things that can compete with the plan"))
                    .hisType(.label, weight: .semibold).foregroundStyle(HisingenTheme.inkMuted)
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conflict.title).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                        Text(conflict.detail).hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hisNotice(HisingenTheme.semanticWarning)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    run { try await model.submitPlan(makeRequest(), vin: state.identity.vin) }
                } label: {
                    Text(activePlan == nil ? L10n.text("Start plan") : L10n.text("Update plan")).frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.hisProminent)
                .disabled(!canSubmit)
                if let plan = activePlan {
                    Button {
                        run { plan.isHeld ? try await model.resumePlan() : try await model.holdPlan() }
                    } label: {
                        Text(plan.isHeld ? L10n.text("Resume plan") : L10n.text("Pause plan")).frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.hisSecondary)
                    .disabled(isBusy)
                }
            }
            if activePlan != nil {
                Button { confirmsCancel = true } label: {
                    Text(L10n.text("Cancel plan")).frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
                .disabled(isBusy)
            }
            if model.link != .live {
                Text(L10n.text("Connect to Home Assistant to change the plan."))
                    .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
            }
        }
    }

    // MARK: - Behaviour

    private func phaseText(_ phase: HomePlanPhase) -> String {
        switch phase {
        case .scheduled: return L10n.text("Scheduled")
        case .charging: return L10n.text("Charging")
        case .waitingForPower: return L10n.text("Waiting for available power")
        case .delayed: return L10n.text("Held by a delayed start")
        case .holding: return L10n.text("Paused until you resume")
        case .override: return L10n.text("Charge now is running")
        case .unlikely: return L10n.text("Target unlikely by the deadline")
        case .attention: return L10n.text("Needs attention")
        case .complete: return L10n.text("Complete")
        case .cancelled: return L10n.text("Cancelled")
        case .expired: return L10n.text("Expired")
        case .idle: return L10n.text("No plan")
        }
    }

    private var previewKey: String {
        "\(kind.rawValue)|\(kind == .addKwh ? kwh : percent)|\(deadline.timeIntervalSince1970)|\(model.link == .live)"
    }

    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        if let plan = activePlan, let target = plan.target, let planned = plan.deadline {
            kind = target.kind
            if target.kind == .addKwh { kwh = target.value } else { percent = target.value }
            deadline = planned
            return
        }
        let needed = ChargingPlannerSupport.neededEnergyKwh(
            batteryPercentage: state.energy.batteryPercentage, targetPercentage: state.energy.targetPercentage, usableCapacityKwh: capacityKwh)
        kwh = min(energyCeiling, max(1, (needed * 2).rounded() / 2))
        percent = min(max(10, percentCeiling), 80)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let earliest = Date().addingTimeInterval(3_600)
        deadline = calendar.nextDate(after: earliest, matching: DateComponents(hour: 7, minute: 0), matchingPolicy: .nextTime) ?? earliest
    }

    private func makeRequest() -> HomeChargingPlanRequest {
        let pairing = pairing ?? NexBlueSetupFallback.pairing
        return HomeChargingPlanRequest(
            planID: UUID().uuidString, chargerID: pairing.chargerID, entities: pairing.entities,
            target: HomePlanTarget(kind: kind, value: kind == .addKwh ? kwh : percent),
            deadline: deadline, timeZoneIdentifier: pairing.timeZoneIdentifier,
            vehicleName: state.identity.modelName ?? state.model.brand.displayName,
            usableCapacityKwh: capacityKwh, chargingLossFactor: ChargingPlannerSupport.chargingLossFactor,
            tibberHome: pairing.tibberHome, networkFeeOrePerKwh: pairing.networkFeeOrePerKwh,
            rateHintKw: preferences.electricityChargerPowerKw)
    }

    private func refreshPreview() async {
        guard model.link == .live, model.componentInstalled != false else { preview = nil; return }
        guard kind == .addKwh || model.capabilities.supportsReachPercent else { preview = nil; return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        do {
            preview = try await model.previewPlan(makeRequest())
            previewProblem = nil
        } catch {
            preview = nil
            previewProblem = error.localizedDescription
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        problem = nil
        Task {
            do { try await work() } catch { problem = error.localizedDescription }
            isBusy = false
        }
    }
}

/// Shown only while the pairing has not loaded yet; never reached once a charger is paired.
private enum NexBlueSetupFallback {
    static let pairing = HomeChargingPairing(
        baseURL: "", chargerID: "", chargerName: "", entities: HomeChargerEntityMap(), vin: "", locationID: nil, locationAlias: "")
}

/// "Edit plan" on the compact card opens the same editor in a sheet.
@MainActor
struct HomeChargingPlanSheet: View {
    let state: VehicleState
    @ObservedObject var model: HomeChargingModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Home charging plan"))
                    .hisType(.displaySmall, weight: HisingenTheme.headingWeight)
                    .foregroundStyle(HisingenTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.text("Done")) { dismiss() }
                    .buttonStyle(.hisSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            PanelRule()
            ScrollView {
                HomeChargingPlanEditor(state: state, model: model)
                    .padding(16)
            }
        }
        .frame(width: 400, height: 560)
        .background(HisingenTheme.canvas)
    }
}

/// The planner card's Home Assistant part: who is in charge, and the editor.
@MainActor
struct HomePlannerSection: View {
    let state: VehicleState
    @ObservedObject var model: HomeChargingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.ownsPlan(for: state.identity.vin) {
                Text(L10n.text("Home Assistant is running this car's plan. Hisingen's own charging schedule stays off until the plan ends or you cancel it."))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hisNotice(HisingenTheme.semanticActive)
            }
            HomeChargingPlanEditor(state: state, model: model)
        }
    }
}
