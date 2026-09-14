import SwiftUI

/// The one-time panel shown after the first successful sign-in. Offers the same feature
/// presets as Settings → Features plus the Polestar command authorization, then never
/// returns: `PreferencesStore.hasCompletedSetupPass` is set only when this view exits,
/// so updates and relaunches stay on the normal dashboard.
@MainActor
struct SetupPassView: View {
    let brand: VehicleBrand
    let onSettingsChanged: (SettingsChange) -> Void
    let onComplete: () -> Void

    @State private var showRemoteConfirmation = false
    @State private var appliedPresetID: String?
    @State private var hasEntered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.preferencesStore) private var preferences

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: HisingenTheme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Set up Hisingen"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(HisingenTheme.ink)
                    Text(L10n.text("Your vehicle is connected. Pick a starting point — everything here can be changed later in Settings → Features."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .staggeredIn(index: 0, hasEntered: hasEntered, reduceMotion: reduceMotion)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(symbol: "sparkles", title: L10n.text("Quick setup"), color: .accentColor)
                        presetButton(id: "recommended",
                                     symbol: "sparkles",
                                     title: L10n.text("Recommended"),
                                     prominent: true) {
                            apply(FeatureSelection.default)
                        }
                        presetButton(id: "safe",
                                     symbol: "checkmark.circle",
                                     title: L10n.text("Enable All Safe Features"),
                                     prominent: false) {
                            apply(FeatureSelection(enabled: Set(AppFeature.safeBulkEnableCases)))
                        }
                        presetButton(id: "remote",
                                     symbol: "key.horizontal",
                                     title: L10n.text("Enable Remote Controls"),
                                     prominent: false) {
                            showRemoteConfirmation = true
                        }
                    }
                }
                .staggeredIn(index: 1, hasEntered: hasEntered, reduceMotion: reduceMotion)

                if brand == .polestar {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            CardHeader(symbol: "key.horizontal", title: L10n.text("Remote commands"), color: .accentColor)
                            Text(L10n.text("Polestar remote controls run through a separate one-time browser authorization."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                onSettingsChanged(.polestarCommandAuthorization)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.forward.app")
                                    Text(L10n.text("Authorize Remote Commands"))
                                }
                                .frame(maxWidth: .infinity, minHeight: 26)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .staggeredIn(index: 2, hasEntered: hasEntered, reduceMotion: reduceMotion)
                }

                Button {
                    onComplete()
                } label: {
                    Text(L10n.text("Done"))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .staggeredIn(index: 3, hasEntered: hasEntered, reduceMotion: reduceMotion)
            }
            .padding(HisingenTheme.sectionSpacing)
        }
        .onAppear { hasEntered = true }
        .confirmationDialog(
            L10n.text("Enable every remote-control feature?"),
            isPresented: $showRemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Enable Remote Controls")) {
                var updated = preferences.features
                for feature in AppFeature.remoteFeatures {
                    updated.set(feature, enabled: true)
                }
                apply(updated, presetID: "remote")
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Remote features can change charging, climate, locks, windows, and vehicle software. Each command still requires an explicit action."))
        }
    }

    @ViewBuilder
    private func presetButton(id: String, symbol: String, title: String,
                              prominent: Bool, action: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: appliedPresetID == id ? "checkmark.circle.fill" : symbol)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            Text(title)
            Spacer()
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 26)
        Group {
            if prominent {
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .accessibilityHint(L10n.text("You can change this later in Settings → Features."))
    }

    private func apply(_ selection: FeatureSelection, presetID: String? = nil) {
        preferences.features = selection
        onSettingsChanged(.features)
        withAnimation(reduceMotion ? nil : Motion.stateChange) {
            appliedPresetID = presetID
        }
    }
}

/// First-run cascade: each section rises in 50 ms after the previous one.
/// The stagger runs once per panel open; Reduce Motion keeps a quick fade
/// and no movement.
private extension View {
    @ViewBuilder
    func staggeredIn(index: Int, hasEntered: Bool, reduceMotion: Bool) -> some View {
        opacity(hasEntered ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (hasEntered ? 0 : 10))
            .animation(reduceMotion ? Motion.resolveCrossfade(Motion.entrance)
                                    : Motion.entrance.delay(Double(index) * 0.05),
                       value: hasEntered)
    }
}
