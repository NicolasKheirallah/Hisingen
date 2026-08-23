import SwiftUI
import AppKit

@MainActor
enum HisingenTheme {
    static var theme: AppTheme { PreferencesStore.shared.appTheme }
    static var isPolestar: Bool { theme == .polestar }


    static var cornerRadius: CGFloat {
        switch theme {
        case .polestar: return 0
        case .cyanRacing: return 8
        case .volvo, .swedishGold: return 10
        case .nordicNight, .sandDune: return 12
        case .hisingen, .forest: return 14
        case .aurora: return 16
        }
    }
    static var cardPadding: CGFloat {
        switch theme {
        case .hisingen, .cyanRacing: return 14
        case .nordicNight, .aurora, .forest: return 15
        case .polestar, .volvo, .swedishGold, .sandDune: return 16
        }
    }
    static let sectionSpacing: CGFloat = 12
    static let smallSpacing: CGFloat = 8
    /// Live panel geometry from the selected size preset / custom overrides /
    /// density zoom, resolved through PanelLayout so every consumer agrees.
    /// Re-evaluated on each layout pass: changing any of the three in Settings
    /// resizes the open dropdown immediately.
    static var panelLayout: PanelLayout { .resolve(from: .shared) }
    static var popoverWidth: CGFloat { panelLayout.width }
    static var popoverIdealHeight: CGFloat { panelLayout.height }
    /// Content zoom factor from the density preset; <1 shows more content in the same
    /// panel, >1 enlarges it.
    static var contentScale: CGFloat { panelLayout.contentScale }
    /// Width that fixed-width views must lay out at *inside* the zoom wrapper: the tree
    /// is laid out at panelWidth / scale and then scaled by `contentScale`, so this —
    /// not `popoverWidth` — keeps those views exactly filling the visible panel.
    static var layoutWidth: CGFloat { panelLayout.logicalWidth }


    // MARK: - Brand Core Colors

    /// Polestar signature Swedish Gold & Amber highlight (#E56E23)
    static let polestarAmber = Color(red: 229/255, green: 110/255, blue: 35/255)

    /// Official Volvo Digital / Electric Blue
    static let volvoBlue = Color(
        light: NSColor(red: 0x00/255, green: 0x5b/255, blue: 0x94/255, alpha: 1),
        dark: NSColor(red: 0x38/255, green: 0xbd/255, blue: 0xf8/255, alpha: 1)
    )

    /// Official Volvo Heritage Iron Navy (#003057)
    static let volvoNavy = Color(
        light: NSColor(red: 0x00/255, green: 0x30/255, blue: 0x57/255, alpha: 1),
        dark: NSColor(red: 0x1e/255, green: 0x3a/255, blue: 0x5f/255, alpha: 1)
    )

    static var canvas: Color {
        switch theme {
        case .volvo:
            return Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1), dark: NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1), dark: NSColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1))
        case .aurora:
            return Color(light: NSColor(red: 0.95, green: 0.99, blue: 0.97, alpha: 1), dark: NSColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1))
        case .swedishGold:
            return Color(light: NSColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1), dark: NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.94, green: 0.98, blue: 1.0, alpha: 1), dark: NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1))
        case .forest:
            return Color(light: NSColor(red: 0.95, green: 0.98, blue: 0.95, alpha: 1), dark: NSColor(red: 0.04, green: 0.09, blue: 0.05, alpha: 1))
        case .sandDune:
            return Color(light: NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1), dark: NSColor(red: 0.09, green: 0.08, blue: 0.07, alpha: 1))
        case .hisingen:
            return Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1), dark: NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        case .polestar:
            return Color(light: NSColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1), dark: NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1))
        }
    }

    static var ink: Color {
        switch theme {
        case .polestar: return Color(light: NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), dark: NSColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
        case .volvo: return Color(light: NSColor(red: 0.06, green: 0.09, blue: 0.15, alpha: 1), dark: NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1))
        case .nordicNight: return Color(light: NSColor(red: 0.02, green: 0.12, blue: 0.20, alpha: 1), dark: NSColor.white)
        case .aurora: return Color(light: NSColor(red: 0.02, green: 0.18, blue: 0.12, alpha: 1), dark: NSColor.white)
        case .swedishGold: return Color(light: NSColor(red: 0.14, green: 0.11, blue: 0.04, alpha: 1), dark: NSColor.white)
        case .cyanRacing: return Color(light: NSColor(red: 0.03, green: 0.12, blue: 0.22, alpha: 1), dark: NSColor.white)
        case .forest: return Color(light: NSColor(red: 0.06, green: 0.16, blue: 0.08, alpha: 1), dark: NSColor.white)
        case .sandDune: return Color(light: NSColor(red: 0.14, green: 0.12, blue: 0.09, alpha: 1), dark: NSColor.white)
        case .hisingen: return Color(light: NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1), dark: NSColor(white: 0.98, alpha: 1))
        }
    }

    static var inkMuted: Color {
        switch theme {
        case .polestar:
            return Color(light: NSColor(red: 0.42, green: 0.42, blue: 0.46, alpha: 1), dark: NSColor(red: 0.65, green: 0.65, blue: 0.70, alpha: 1))
        case .volvo:
            return Color(light: NSColor(red: 0.35, green: 0.42, blue: 0.50, alpha: 1), dark: NSColor(red: 0.60, green: 0.68, blue: 0.76, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.08, green: 0.42, blue: 0.58, alpha: 1), dark: NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1))
        case .aurora:
            return Color(light: NSColor(red: 0.06, green: 0.45, blue: 0.32, alpha: 1), dark: NSColor(red: 0.28, green: 0.82, blue: 0.60, alpha: 1))
        case .swedishGold:
            return Color(light: NSColor(red: 0.48, green: 0.36, blue: 0.10, alpha: 1), dark: NSColor(red: 0.90, green: 0.82, blue: 0.55, alpha: 1))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.08, green: 0.42, blue: 0.58, alpha: 1), dark: NSColor(red: 0.45, green: 0.80, blue: 0.98, alpha: 1))
        case .forest:
            return Color(light: NSColor(red: 0.18, green: 0.42, blue: 0.22, alpha: 1), dark: NSColor(red: 0.52, green: 0.88, blue: 0.65, alpha: 1))
        case .sandDune:
            return Color(light: NSColor(red: 0.42, green: 0.36, blue: 0.30, alpha: 1), dark: NSColor(red: 0.82, green: 0.76, blue: 0.70, alpha: 1))
        case .hisingen:
            return Color(light: NSColor(red: 0.38, green: 0.44, blue: 0.52, alpha: 1), dark: NSColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1))
        }
    }

    static var hairline: Color {
        switch theme {
        case .polestar:
            return Color(light: NSColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1), dark: NSColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1))
        case .volvo:
            return Color(light: NSColor(red: 0.86, green: 0.89, blue: 0.93, alpha: 1), dark: NSColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.0, green: 0.60, blue: 0.80, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.25))
        case .aurora:
            return Color(light: NSColor(red: 0.0, green: 0.65, blue: 0.35, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.90, blue: 0.46, alpha: 0.25))
        case .swedishGold:
            return Color(light: NSColor(red: 0.72, green: 0.52, blue: 0.05, alpha: 0.35), dark: NSColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 0.30))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.0, green: 0.48, blue: 0.78, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.56, blue: 0.82, alpha: 0.30))
        case .forest:
            return Color(light: NSColor(red: 0.14, green: 0.48, blue: 0.18, alpha: 0.35), dark: NSColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 0.25))
        case .sandDune:
            return Color(light: NSColor(red: 0.65, green: 0.50, blue: 0.25, alpha: 0.35), dark: NSColor(red: 0.77, green: 0.63, blue: 0.35, alpha: 0.30))
        case .hisingen:
            return Color(light: NSColor(white: 0.0, alpha: 0.08), dark: NSColor(white: 1.0, alpha: 0.12))
        }
    }

    static var accent: Color {
        switch theme {
        case .polestar:
            return Color(light: NSColor(red: 0.90, green: 0.43, blue: 0.14, alpha: 1), dark: NSColor(red: 1.0, green: 0.54, blue: 0.24, alpha: 1))
        case .volvo:
            return Color(light: NSColor(red: 0.0, green: 0.36, blue: 0.58, alpha: 1), dark: NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1))
        case .hisingen:
            return Color(light: NSColor(red: 0.88, green: 0.38, blue: 0.05, alpha: 1), dark: NSColor(red: 0.96, green: 0.50, blue: 0.15, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.0, green: 0.55, blue: 0.75, alpha: 1), dark: NSColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 1))
        case .aurora:
            return Color(light: NSColor(red: 0.0, green: 0.60, blue: 0.35, alpha: 1), dark: NSColor(red: 0.0, green: 0.92, blue: 0.50, alpha: 1))
        case .swedishGold:
            return Color(light: NSColor(red: 0.72, green: 0.52, blue: 0.05, alpha: 1), dark: NSColor(red: 0.88, green: 0.72, blue: 0.22, alpha: 1))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.0, green: 0.48, blue: 0.78, alpha: 1), dark: NSColor(red: 0.0, green: 0.65, blue: 0.95, alpha: 1))
        case .forest:
            return Color(light: NSColor(red: 0.14, green: 0.48, blue: 0.18, alpha: 1), dark: NSColor(red: 0.30, green: 0.78, blue: 0.35, alpha: 1))
        case .sandDune:
            return Color(light: NSColor(red: 0.65, green: 0.50, blue: 0.25, alpha: 1), dark: NSColor(red: 0.82, green: 0.68, blue: 0.42, alpha: 1))
        }
    }

    static func liquidGlassSpecularBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color(light: NSColor(white: 1.0, alpha: 0.85), dark: NSColor(white: 1.0, alpha: 0.30)), location: 0.0),
                        .init(color: Color(light: NSColor(white: 1.0, alpha: 0.35), dark: NSColor(white: 1.0, alpha: 0.08)), location: 0.35),
                        .init(color: Color(light: NSColor(white: 0.0, alpha: 0.04), dark: NSColor(white: 0.0, alpha: 0.30)), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }

    static var cardBackground: AnyShapeStyle {
        switch theme {
        case .hisingen: return AnyShapeStyle(.regularMaterial)
        case .polestar: return AnyShapeStyle(Color(light: NSColor.white, dark: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)))
        case .volvo: return AnyShapeStyle(Color(light: NSColor.white, dark: NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1.0)))
        default: return AnyShapeStyle(canvas)
        }
    }
    static var cardBorderWidth: CGFloat {
        switch theme {
        case .hisingen: return 0.5
        default: return 1
        }
    }
    static var cardShadowOpacity: Double {
        switch theme {
        case .polestar: return 0
        case .volvo: return 0.03
        default: return 0.04
        }
    }
    static var cardShadowRadius: CGFloat {
        switch theme {
        case .polestar: return 0
        case .volvo: return 4
        default: return 6
        }
    }

    static var popoverBackground: AnyShapeStyle {
        switch theme {
        case .hisingen: return AnyShapeStyle(.ultraThinMaterial)
        default: return AnyShapeStyle(canvas)
        }
    }

    /// Full-bleed popover surface. The Hisingen glass theme layers Apple's translucent
    /// material with a specular light wash and a soft vignette so the window reads as
    /// clear Liquid Glass over the desktop (the popover backing itself is cleared in
    /// StatusItemController.showPopover). Other themes keep their opaque canvas.
    @ViewBuilder
    static var popoverSurface: some View {
        if theme == .hisingen {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    stops: [
                        .init(color: Color(light: NSColor(white: 1.0, alpha: 0.50), dark: NSColor(white: 1.0, alpha: 0.07)), location: 0.0),
                        .init(color: .clear, location: 0.45),
                        .init(color: Color(light: NSColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 0.05), dark: NSColor(white: 0.0, alpha: 0.16)), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            Rectangle().fill(popoverBackground)
        }
    }

    static var headingWeight: Font.Weight {
        switch theme {
        case .polestar: return .regular
        case .volvo, .sandDune: return .medium
        case .hisingen, .nordicNight, .aurora, .forest: return .semibold
        case .swedishGold, .cyanRacing: return .bold
        }
    }
    static var valueWeight: Font.Weight {
        switch theme {
        case .polestar: return .regular
        case .volvo, .sandDune: return .medium
        case .hisingen, .nordicNight, .aurora, .forest: return .semibold
        case .swedishGold, .cyanRacing: return .bold
        }
    }
    static var displayWeight: Font.Weight {
        switch theme {
        case .polestar: return .regular
        case .volvo, .cyanRacing: return .black
        case .nordicNight, .swedishGold: return .heavy
        case .hisingen, .aurora, .forest, .sandDune: return .bold
        }
    }
    static var displayTracking: CGFloat {
        switch theme {
        case .polestar: return -1.2
        case .cyanRacing: return -0.8
        case .swedishGold: return -0.6
        case .nordicNight: return -0.5
        case .volvo: return -0.4
        case .sandDune: return -0.3
        case .aurora: return -0.2
        case .hisingen, .forest: return 0
        }
    }

    static func decorativeTint(_ preferred: Color) -> Color {
        switch theme {
        case .polestar: return inkMuted
        case .volvo: return volvoNavy.opacity(0.75)
        case .hisingen: return preferred
        default: return accent.opacity(0.8)
        }
    }


    static let semanticGood = Color.green

    /// Chart series tokens. Themes with a strong accent identity (Polestar's monochrome
    /// philosophy, Volvo Iron) collapse charts toward the theme accent; expressive themes
    /// keep distinct hues so multi-series cards stay readable.
    static var chartPositive: Color { decorativeTint(.green) == .green ? .green : HisingenTheme.accent }
    static var chartInfo: Color { decorativeTint(.cyan) == .cyan ? .cyan : HisingenTheme.accent.opacity(0.85) }
    static var chartAttention: Color { decorativeTint(.orange) == .orange ? .orange : HisingenTheme.accent.opacity(0.7) }
    static var chartHealth: Color { decorativeTint(.pink) == .pink ? .pink : HisingenTheme.accent.opacity(0.9) }
    static let semanticActive = Color.blue
    static let semanticWarning = Color.orange
    static let semanticCritical = Color.red

    /// UI severity color for a tyre's reported warning level: green when explicitly OK,
    /// red for critically low, orange for low/high, muted gray when nothing was reported.
    static func tyreWarningColor(_ warning: TyrePressureWarning) -> Color {
        switch warning {
        case .none: return semanticGood
        case .veryLow: return semanticCritical
        case .low, .high: return semanticWarning
        case .unknown: return Color.secondary
        }
    }

    static func batteryColor(percentage: Double, charging: Bool) -> Color {
        if percentage <= 15 { return semanticCritical }
        if percentage <= 35 { return .yellow }
        if charging {


            return percentage >= 80 ? semanticGood : accent
        }
        return .accentColor
    }

    static func fuelColor(percentage: Double) -> Color {
        if percentage <= 12 { return semanticCritical }
        if percentage <= 25 { return semanticWarning }
        return Color(red: 0.96, green: 0.60, blue: 0.12)
    }

    static func statusColor(state: ChargingState) -> Color {
        if state == .fault { return semanticWarning }
        if state.isActivelyCharging { return semanticGood }
        return .secondary
    }

    static func temperatureColor(celsius: Double) -> Color {
        if celsius < 20.0 { return semanticActive }
        if celsius > 22.0 { return polestarAmber }
        return .primary
    }
}

extension Color {


    init(light: NSColor, dark: NSColor) {
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            let isDark: Bool
            if let match = appearance.bestMatch(from: [.darkAqua, .aqua]) {
                isDark = (match == .darkAqua)
            } else {
                isDark = appearance.name.rawValue.lowercased().contains("dark")
            }
            return isDark ? dark : light
        }))
    }

    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hexSanitized.hasPrefix("#") {
            hexSanitized.remove(at: hexSanitized.startIndex)
        }
        guard hexSanitized.count == 6, let rgbValue = UInt64(hexSanitized, radix: 16) else { return nil }
        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}

extension View {
    func withoutFocusRing() -> some View {
        self.focusable(false).focusEffectDisabled()
    }
}


@MainActor
struct WholeRowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .withoutFocusRing()

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

@MainActor
struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let radius = HisingenTheme.cornerRadius
        content
            .padding(HisingenTheme.cardPadding)
            .background {
                ZStack {
                    if HisingenTheme.theme == .hisingen {
                        // Apple Liquid Glass dynamic material
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.regularMaterial)
                        // Specular subtle light wash
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(light: NSColor(white: 1.0, alpha: 0.45), dark: NSColor(white: 1.0, alpha: 0.05)),
                                        Color(light: NSColor(white: 1.0, alpha: 0.10), dark: NSColor(white: 0.0, alpha: 0.12))
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else if HisingenTheme.theme == .polestar {
                        // Polestar stark minimalist architectural panel
                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .fill(Color(light: NSColor.white, dark: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)))
                    } else if HisingenTheme.theme == .volvo {
                        // Volvo Scandinavian luxury frosted glass card with subtle iron navy wash
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.regularMaterial)
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(light: NSColor(white: 1.0, alpha: 0.75), dark: NSColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 0.65)),
                                        Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 0.45), dark: NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 0.45))
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        // Translucent frosted glass tinted with theme canvas
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.regularMaterial)
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(HisingenTheme.canvas.opacity(0.60))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                ZStack {
                    if radius > 0 {
                        HisingenTheme.liquidGlassSpecularBorder(cornerRadius: radius)
                    }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(HisingenTheme.hairline, lineWidth: HisingenTheme.cardBorderWidth)
                }
            )
            .shadow(color: Color.black.opacity(HisingenTheme.isPolestar ? 0 : 0.03), radius: 2, x: 0, y: 1)
            .shadow(color: Color.black.opacity(HisingenTheme.isPolestar ? 0 : HisingenTheme.cardShadowOpacity), radius: HisingenTheme.cardShadowRadius, x: 0, y: 3)
    }
}

struct CardHeader: View {
    let symbol: String
    let title: String
    let color: Color
    var isSemantic: Bool = false
    var isPulsing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(isSemantic ? color : HisingenTheme.decorativeTint(color))
                .font(.system(size: 13, weight: HisingenTheme.headingWeight))
                .scaleEffect(isPulsing && pulse ? 1.15 : 1.0)
                .shadow(color: isPulsing && pulse ? color.opacity(0.6) : .clear, radius: 4)
                .animation(
                    isPulsing && !reduceMotion
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear {
                    if isPulsing && !reduceMotion {
                        pulse = true
                    }
                }
            Text(title)
                .font(.system(size: 13, weight: HisingenTheme.headingWeight))
                .foregroundStyle(HisingenTheme.ink)
            Spacer()
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color
    let symbol: String?
    init(text: String, color: Color, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }
    var body: some View {
        let isPolestar = HisingenTheme.cornerRadius == 0
        let radius: CGFloat = isPolestar ? 0 : 5
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 10.5, weight: HisingenTheme.valueWeight))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(color.opacity(0.28), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}


@MainActor
struct StateSummaryChip: View {
    let message: String
    let severity: VehicleStateSeverity

    private var color: Color {
        switch severity {
        case .neutral: return .secondary
        case .good: return HisingenTheme.semanticGood
        case .warning: return HisingenTheme.semanticWarning
        case .critical: return HisingenTheme.semanticCritical
        }
    }

    private var symbol: String {
        switch severity {
        case .neutral: return "info.circle.fill"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var chipRadius: CGFloat { HisingenTheme.cornerRadius == 0 ? 0 : 9 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: HisingenTheme.headingWeight))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}


enum CapabilityState {
    case unsupported
    case unavailable
    case unknown

    var label: String {
        switch self {
        case .unsupported: return L10n.text("Unsupported")
        case .unavailable: return L10n.text("Temporarily unavailable")
        case .unknown: return L10n.text("Not yet checked")
        }
    }

    var symbol: String {
        switch self {
        case .unsupported: return "minus.circle"
        case .unavailable: return "wifi.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct CapabilityBadge: View {
    let title: String
    let state: CapabilityState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
                .font(.system(size: 11, weight: HisingenTheme.headingWeight))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
                .foregroundStyle(.secondary)
            Spacer()
            Text(state.label)
                .font(.system(size: 10.5, weight: HisingenTheme.valueWeight))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(state.label)")
    }
}

struct InformationButton: View {
    let message: String
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(message)
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel(L10n.text("Details"))
        .accessibilityHint(message)
    }
}

struct KVRow: View {
    let key: String
    let value: String
    let symbol: String?
    let valueWarning: Bool
    let warning: Bool


    let info: String?
    init(_ key: String, _ value: String, symbol: String? = nil, valueWarning: Bool = false, warning: Bool = false, info: String? = nil) {
        self.key = key
        self.value = value
        self.symbol = symbol
        self.valueWarning = valueWarning
        self.warning = warning
        self.info = info
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(warning ? HisingenTheme.semanticWarning : .secondary)
                    .accessibilityHidden(true)
            }
            Text(key)
                .foregroundStyle(warning ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
                .font(.system(size: 12, weight: .regular))
            if let info {
                InformationButton(message: info)
            }
            Spacer()
            Text(value)
                .foregroundStyle(valueWarning ? HisingenTheme.semanticWarning : HisingenTheme.ink)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
        .accessibilityElement(children: info == nil ? .ignore : .contain)
        .accessibilityLabel({
            var label = warning || valueWarning ? "\(L10n.text("Warning")): \(key), \(value)" : "\(key): \(value)"
            if let info { label += ". \(info)" }
            return label
        }())
    }
}


private struct ChargingFlowHighlight: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    private let coreWidth: CGFloat = 38
    private let haloWidth: CGFloat = 72
    private let speed: CGFloat = 46

    private func trail(peakOpacity: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0.0),
                .init(color: .white.opacity(peakOpacity * 0.3), location: 0.55),
                .init(color: .white.opacity(peakOpacity), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let travel = width + haloWidth
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let cycle = Double(travel / speed)
            let x = cycle > 0
                ? CGFloat(elapsed.truncatingRemainder(dividingBy: cycle)) * speed - haloWidth
                : -haloWidth

            ZStack(alignment: .leading) {
                trail(peakOpacity: 0.4)
                    .frame(width: haloWidth, height: height)
                    .blur(radius: 3.5)
                    .offset(x: x)
                trail(peakOpacity: 0.95)
                    .frame(width: coreWidth, height: height)
                    .offset(x: x + (haloWidth - coreWidth) / 2)
            }
        }
        .frame(width: max(0, width), height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
struct BatteryGauge: View {
    let fraction: Double
    let targetFraction: Double?
    let color: Color
    var isCharging: Bool = false

    @State private var breathingGlow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accessibilityValue: String {
        let percent = Int((fraction * 100).rounded())
        if let targetFraction {
            let target = Int((targetFraction * 100).rounded())
            return L10n.format("Battery %d percent, target %d percent", percent, target)
        }
        return L10n.format("Battery %d percent", percent)
    }


    private var isPolestar: Bool { PreferencesStore().appTheme == .polestar }
    private var gaugeRadius: CGFloat { isPolestar ? 0 : 5 }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let width = geo.size.width
                let currentWidth = max(0, width * CGFloat(min(max(fraction, 0), 1)))


                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(HisingenTheme.ink.opacity(0.08))
                    .frame(height: 9)


                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(
                        isPolestar
                            ? AnyShapeStyle(color)
                            : AnyShapeStyle(LinearGradient(
                                colors: [color.opacity(0.85), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    )
                    .frame(width: currentWidth, height: 9)
                    .shadow(color: isPolestar ? .clear : color.opacity(isCharging ? (breathingGlow ? 0.65 : 0.25) : 0.35),
                            radius: isPolestar ? 0 : (isCharging ? (breathingGlow ? 6 : 2) : 4),
                            x: 0, y: 1)
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                    .animation(.easeInOut(duration: 0.4), value: color)


                if isCharging && !reduceMotion && !isPolestar {
                    ChargingFlowHighlight(width: currentWidth, height: 9, cornerRadius: gaugeRadius)


                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                        .blur(radius: breathingGlow ? 5 : 2.5)
                        .opacity(breathingGlow ? 0.95 : 0.55)
                        .blendMode(.plusLighter)
                        .offset(x: currentWidth - 4.5)
                        .allowsHitTesting(false)
                }


                if let targetFraction {
                    let targetX = width * CGFloat(min(max(targetFraction, 0), 1)) - 1.5
                    RoundedRectangle(cornerRadius: isPolestar ? 0 : 1.5)
                        .fill(HisingenTheme.ink.opacity(0.75))
                        .frame(width: 3, height: 13)
                        .offset(x: targetX, y: -2)
                        .shadow(color: .black.opacity(isPolestar ? 0 : 0.2), radius: isPolestar ? 0 : 1, x: 0, y: 1)
                }
            }
        }
        .frame(height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
        .onAppear {
            if isCharging && !reduceMotion && !isPolestar {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    breathingGlow = true
                }
            }
        }
        .onChange(of: isCharging) { _, charging in
            guard !reduceMotion else { return }
            if charging {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    breathingGlow = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    breathingGlow = false
                }
            }
        }
    }
}

@MainActor
struct FuelGauge: View {
    let fraction: Double
    let color: Color

    private var isPolestar: Bool { PreferencesStore().appTheme == .polestar }
    private var gaugeRadius: CGFloat { isPolestar ? 0 : 5 }

    private var accessibilityValue: String {
        let percent = Int((fraction * 100).rounded())
        return L10n.format("Fuel tank %d percent", percent)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let width = geo.size.width
                let currentWidth = max(0, width * CGFloat(min(max(fraction, 0), 1)))

                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(HisingenTheme.ink.opacity(0.08))
                    .frame(height: 9)

                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(
                        isPolestar
                            ? AnyShapeStyle(color)
                            : AnyShapeStyle(LinearGradient(
                                colors: [color.opacity(0.85), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    )
                    .frame(width: currentWidth, height: 9)
                    .shadow(color: isPolestar ? .clear : color.opacity(0.35),
                            radius: isPolestar ? 0 : 3,
                            x: 0, y: 1)
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                    .animation(.easeInOut(duration: 0.4), value: color)
            }
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
    }
}

@MainActor
struct DualEnergyGauge: View {
    let batteryFraction: Double?
    let fuelFraction: Double?
    let batteryColor: Color
    let fuelColor: Color
    var isCharging: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: isCharging ? "bolt.fill" : "battery.100percent")
                        .font(.system(size: 9))
                        .foregroundStyle(batteryColor)
                    Text(L10n.text("Battery"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(batteryFraction.map { String(format: "%.0f%%", min(max($0 * 100, 0), 100)) } ?? "—")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                }
                if let batteryFraction {
                    BatteryGauge(
                        fraction: batteryFraction,
                        targetFraction: nil,
                        color: batteryColor,
                        isCharging: isCharging
                    )
                } else {
                    UnavailableEnergyGauge()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: "fuelpump.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(fuelColor)
                    Text(L10n.text("Fuel"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(fuelFraction.map { String(format: "%.0f%%", min(max($0 * 100, 0), 100)) } ?? "—")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                }
                if let fuelFraction {
                    FuelGauge(
                        fraction: fuelFraction,
                        color: fuelColor
                    )
                } else {
                    UnavailableEnergyGauge()
                }
            }
        }
    }
}

@MainActor
struct UnavailableEnergyGauge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PreferencesStore().appTheme == .polestar ? 0 : 5, style: .continuous)
            .fill(HisingenTheme.ink.opacity(0.08))
            .frame(height: 9)
            .accessibilityLabel(L10n.text("Energy level unavailable"))
    }
}

@MainActor
struct SeatHeatingControl: View {
    let title: String
    @Binding var level: HeatingLevel
    let onChange: @MainActor (HeatingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                let nextLevel: HeatingLevel
                switch level {
                case .unspecified, .off: nextLevel = .level1
                case .level1: nextLevel = .level2
                case .level2: nextLevel = .level3
                case .level3: nextLevel = .off
                }
                level = nextLevel
                onChange(nextLevel)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "carseat.left.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(level != .off && level != .unspecified ? Color.orange : Color.secondary)


                    HStack(spacing: 2) {
                        ForEach(1...3, id: \.self) { bar in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(barActive(bar) ? Color.orange : Color.secondary.opacity(0.25))
                                .frame(width: 4, height: 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func barActive(_ bar: Int) -> Bool {
        switch level {
        case .level1: return bar == 1
        case .level2: return bar <= 2
        case .level3: return true
        default: return false
        }
    }
}

@MainActor
struct SteeringHeatingControl: View {
    @Binding var level: HeatingLevel
    let onChange: @MainActor (HeatingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Steering Wheel"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                let next = (level == .level3 || level == .level2 || level == .level1) ? HeatingLevel.off : HeatingLevel.level3
                level = next
                onChange(next)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "steeringwheel")
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? Color.orange : Color.secondary)
                    Text(L10n.text(isActive ? "ON" : "OFF"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isActive ? Color.orange : Color.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var isActive: Bool {
        level == .level3 || level == .level2 || level == .level1
    }
}
