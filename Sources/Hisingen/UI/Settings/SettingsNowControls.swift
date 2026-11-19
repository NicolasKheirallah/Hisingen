import SwiftUI

@MainActor
struct SettingsNowControls: View {
    let binder: PreferenceBinder
    let state: VehicleState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferences: PreferencesStore { binder.preferences }

    /// Which control cards sit under the car on Now, drawn as the cards themselves. A chosen tile
    /// carries its position on Now; the order is the order the reader picked them in.
    var body: some View {
        let chosen = preferences.nowQuickControls
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Controls on Now"))
                .hisType(.label, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("Choose the control cards shown under the car. Each still needs its remote feature turned on."))
                .hisType(.caption)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(NowQuickControl.allCases, id: \.self) { control in
                    nowControlTile(control, position: chosen.firstIndex(of: control).map { $0 + 1 })
                }
            }
            Picker(L10n.text("Limit step"), selection: binder(\.nowLimitStep, .panelLayout)) {
                ForEach(LimitStep.allCases, id: \.self) { step in
                    Text(step.title).tag(step)
                }
            }
            .padding(.top, 4)
            Text(L10n.text("Each press raises a limit by this share of the highest value your car allows."))
                .hisType(.caption)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleNowControl(_ control: NowQuickControl) {
        var chosen = preferences.nowQuickControls
        if let index = chosen.firstIndex(of: control) {
            chosen.remove(at: index)
        } else {
            chosen.append(control)
        }
        withAnimation(reduceMotion ? nil : Motion.selection) {
            preferences.nowQuickControls = chosen
        }
        binder.bump()
        binder.notify(.panelLayout)
    }

    /// Why a chosen control will not draw on this car, or nil when it will.
    private func nowControlBlocker(_ control: NowQuickControl) -> String? {
        let features = preferences.features.enabled
        if !features.contains(control.feature), control != .locks, control != .climate, control != .charging {
            return L10n.format("%@ · %@", control.feature.title, L10n.text("Off"))
        }
        guard let state else { return nil }
        let drawn = NowQuickControl.applicable(
            [control], features: features,
            hasElectricRange: state.powertrain.hasElectricRange,
            profile: state.capabilityProfile,
            supportsTrunkControl: state.otaCapabilities?.supportsTrunkControl == true
        )
        return drawn.isEmpty ? L10n.text("Unavailable") : nil
    }

    private func nowControlSymbol(_ control: NowQuickControl) -> String {
        switch control {
        case .locks: return "lock"
        case .climate: return "fan"
        case .charging: return "bolt"
        case .chargeLimit: return "battery.75percent"
        case .currentLimit: return "gauge.with.dots.needle.bottom.100percent"
        case .airCleaning: return "aqi.medium"
        case .windows: return "car.window.left"
        case .locate: return "light.beacon.max"
        case .tailgate: return "car.side.rear.open"
        }
    }

    private func nowControlTile(_ control: NowQuickControl, position: Int?) -> some View {
        let selected = position != nil
        let blocker = nowControlBlocker(control)
        return Button { toggleNowControl(control) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(position.map { "\($0)" } ?? " ")
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                        .accessibilityHidden(true)
                    Spacer()
                    Image(systemName: nowControlSymbol(control))
                        .hisSymbolSize(13)
                        .foregroundStyle(selected ? HisingenTheme.ink : HisingenTheme.inkMuted)
                        .accessibilityHidden(true)
                }
                Text(control.title)
                    .hisType(.subhead)
                    .foregroundStyle(selected ? HisingenTheme.ink : HisingenTheme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let blocker {
                    Text(blocker)
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(selected ? HisingenTheme.palette.studioFill : HisingenTheme.canvas)
            .overlay(
                Rectangle().strokeBorder(selected ? HisingenTheme.ink : HisingenTheme.hairline,
                                         lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(control.title)
        .accessibilityValue([position.map { L10n.format("%d of %d cards", $0, preferences.nowQuickControls.count) }, blocker]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

}
