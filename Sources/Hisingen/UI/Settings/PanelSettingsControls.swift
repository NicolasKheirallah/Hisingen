import SwiftUI

/// Anything the panel-settings segmented rows can render: the app's size and
/// density presets share title/subtitle/symbol shape already, this just makes
/// it a contract so one generic row serves both.
@MainActor
protocol PresetOptionDisplaying: Hashable {
    var title: String { get }
    var subtitle: String { get }
    var symbol: String { get }
}

extension PanelSize: PresetOptionDisplaying {}
extension ContentDensity: PresetOptionDisplaying {}
extension WideCardLayout: PresetOptionDisplaying {}

/// The icon-tile selector used for Panel Size and Content Density. Extracted
/// from two verbatim copies in SettingsView; also carries proper VoiceOver
/// metadata (label + selected trait), which the copies only had as tooltips.
@MainActor
struct SegmentedPresetRow<Option: PresetOptionDisplaying>: View {
    let options: [Option]
    @Binding var selection: Option

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(reduceMotion ? nil : Motion.interaction) {
                        selection = option
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol)
                            .hisType(.heading, weight: isSelected ? .semibold : .regular)
                        Text(option.title)
                            .hisType(.caption, weight: isSelected ? .semibold : .regular)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                    )
                    .foregroundStyle(isSelected ? HisingenTheme.accent : HisingenTheme.ink)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(option.title). \(option.subtitle)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .help("\(option.title) – \(option.subtitle)")
            }
        }
    }
}

/// Proportional miniature of the resolved panel against a ghost of the
/// Standard preset, so users see relative size/density at a glance instead of
/// parsing "540 × 580 pt". Matches the preview-first language of the theme
/// and menu-bar setting cards.
@MainActor
struct PanelProportionPreview: View {
    let layout: PanelLayout

    private static let reference = CGSize(width: PanelSize.standard.width,
                                          height: PanelSize.standard.idealHeight)

    var body: some View {
        let box = CGSize(width: 118, height: 72)
        let fit = min(box.width / Self.reference.width, box.height / Self.reference.height)
        let ghost = CGSize(width: Self.reference.width * fit, height: Self.reference.height * fit)
        let actual = CGSize(width: layout.width * fit, height: layout.unclampedHeight * fit)

        return ZStack {
            // Ghost of the Standard preset for comparison.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.30), lineWidth: 0.8)
                .frame(width: ghost.width, height: ghost.height)
            // Current resolution (custom overrides included).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HisingenTheme.accent.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(HisingenTheme.accent.opacity(0.55), lineWidth: 1)
                )
                .frame(width: actual.width, height: actual.height)
            Text("\(Int(layout.width)) × \(Int(layout.unclampedHeight))")
                .hisType(.micro, weight: .semibold, design: .monospaced)
                .foregroundStyle(HisingenTheme.ink)
        }
        .frame(width: box.width, height: box.height)
        // Ghost and current rectangles settle between presets instead of snapping.
        .hisAnimation(Motion.layout, value: layout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("Panel is %@ points wide and %@ points tall",
                                        String(Int(layout.width)), String(Int(layout.unclampedHeight))))
    }
}

/// Independent width/height overrides for the dropdown. Sliders are disabled
/// until enabled; turning the toggle on seeds them from the currently resolved
/// geometry so the panel never jumps.
@MainActor
struct PanelCustomSizeControls: View {
    @Binding var isEnabled: Bool
    @Binding var width: Double
    @Binding var height: Double
    /// True when a custom size was already committed (persisted) when the control
    /// appeared – enabling custom mode must not clobber it with the preset.
    let hasCommittedSize: Bool
    /// Seeds the sliders from the active preset the first time custom mode turns on.
    let seedValues: () -> (width: Double, height: Double)
    /// Fired after any persisted change so the host can emit `.presentation`.
    let onCommit: () -> Void

    /// A custom size committed interactively since this control was mounted.
    @State private var committedWhileVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Custom Size"))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text("Independent width and height overrides"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isEnabled) { _, newValue in
                        // Seed from the resolved geometry on the false→true transition,
                        // but only when no custom size was previously committed – the
                        // host always initializes positive values, so a width/height == 0
                        // check would never fire.
                        if newValue && !hasCommittedSize && !committedWhileVisible {
                            let seeded = seedValues()
                            width = seeded.width
                            height = seeded.height
                        }
                        onCommit()
                    }
            }

            if isEnabled {
                Group {
                    dimensionSlider(
                        label: L10n.text("Width"),
                        value: $width,
                        range: PanelLayout.minimumWidth...PanelLayout.maximumWidth,
                        step: 10
                    )
                    dimensionSlider(
                        label: L10n.text("Height"),
                        value: $height,
                        range: PanelLayout.minimumHeight...PanelLayout.maximumHeight,
                        step: 20
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .hisAnimation(Motion.layout, value: isEnabled)
    }

    private func dimensionSlider(label: String, value: Binding<Double>,
                                 range: ClosedRange<CGFloat>, step: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .hisType(.label)
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { newValue in
                    let snapped = (newValue / Double(step)).rounded() * Double(step)
                    if snapped != value.wrappedValue {
                        value.wrappedValue = snapped
                        committedWhileVisible = true
                        onCommit()
                    }
                }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(Int(value.wrappedValue))")
                // `design: .monospaced` already gives tabular figures; the extra
                // `.monospacedDigit()` was a no-op.
                .hisType(.caption, weight: .semibold, design: .monospaced)
                .frame(width: 32, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}
