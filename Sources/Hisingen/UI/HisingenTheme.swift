import SwiftUI
import AppKit

@MainActor
enum HisingenTheme {
    private static var isPolestar: Bool { Preferences.appTheme == .polestar }


    static var cornerRadius: CGFloat { isPolestar ? 0 : 14 }
    static var cardPadding: CGFloat { isPolestar ? 16 : 14 }
    static let sectionSpacing: CGFloat = 12
    static let smallSpacing: CGFloat = 8
    static let popoverWidth: CGFloat = 430


    static let polestarAmber = Color(red: 229/255, green: 110/255, blue: 35/255)


    static var canvas: Color {
        Color(light: NSColor.white, dark: NSColor(red: 0x1a/255, green: 0x1a/255, blue: 0x1a/255, alpha: 1))
    }


    static var ink: Color { isPolestar ? Color(light: NSColor.black, dark: NSColor.white) : .primary }

    static var inkMuted: Color {
        isPolestar
            ? Color(light: NSColor(red: 0x66/255, green: 0x66/255, blue: 0x66/255, alpha: 1),
                    dark: NSColor(red: 0xbb/255, green: 0xbb/255, blue: 0xbb/255, alpha: 1))
            : .secondary
    }

    static var hairline: Color {
        isPolestar
            ? Color(light: NSColor(red: 0xe5/255, green: 0xe5/255, blue: 0xe5/255, alpha: 1),
                    dark: NSColor(red: 0x2b/255, green: 0x2b/255, blue: 0x2b/255, alpha: 1))
            : Color(nsColor: .separatorColor).opacity(0.35)
    }


    static var accent: Color { isPolestar ? ink : polestarAmber }

    static var cardBackground: AnyShapeStyle {
        isPolestar ? AnyShapeStyle(canvas) : AnyShapeStyle(.regularMaterial)
    }
    static var cardBorderWidth: CGFloat { isPolestar ? 1 : 0.5 }
    static var cardShadowOpacity: Double { isPolestar ? 0 : 0.04 }
    static var cardShadowRadius: CGFloat { isPolestar ? 0 : 6 }

    static var popoverBackground: AnyShapeStyle {
        isPolestar ? AnyShapeStyle(canvas) : AnyShapeStyle(.ultraThinMaterial)
    }


    static var headingWeight: Font.Weight { isPolestar ? .regular : .semibold }
    static var valueWeight: Font.Weight { isPolestar ? .regular : .semibold }
    static var displayWeight: Font.Weight { isPolestar ? .regular : .bold }


    static var displayTracking: CGFloat { isPolestar ? -1.2 : 0 }


    static func decorativeTint(_ preferred: Color) -> Color {
        isPolestar ? inkMuted : preferred
    }


    static let semanticGood = Color.green


    static let semanticActive = Color.blue


    static let semanticWarning = Color.orange

    static let semanticCritical = Color.red

    static func batteryColor(percentage: Double, charging: Bool) -> Color {
        if percentage <= 15 { return semanticCritical }
        if percentage <= 35 { return .yellow }
        if charging {
            return percentage >= 80 ? semanticGood : semanticActive
        }
        return .accentColor
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

private extension Color {


    init(light: NSColor, dark: NSColor) {
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }))
    }
}


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

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(HisingenTheme.cardPadding)
            .background(HisingenTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius, style: .continuous)
                    .stroke(HisingenTheme.hairline, lineWidth: HisingenTheme.cardBorderWidth)
            )
            .shadow(color: .black.opacity(HisingenTheme.cardShadowOpacity), radius: HisingenTheme.cardShadowRadius, x: 0, y: 2)
    }
}

struct CardHeader: View {
    let symbol: String
    let title: String
    let color: Color


    var isSemantic: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(isSemantic ? color : HisingenTheme.decorativeTint(color))
                .font(.system(size: 13, weight: HisingenTheme.headingWeight))
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
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 11, weight: HisingenTheme.valueWeight))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}


struct StateSummaryChip: View {
    let message: String
    let severity: VehicleStateSeverity

    private var color: Color {
        switch severity {
        case .good: return HisingenTheme.semanticGood
        case .warning: return HisingenTheme.semanticWarning
        case .critical: return HisingenTheme.semanticCritical
        }
    }

    private var symbol: String {
        switch severity {
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
        HStack(spacing: 6) {
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
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help(info)
                    .accessibilityHidden(true)
            }
            Spacer()
            Text(value)
                .foregroundStyle(valueWarning ? HisingenTheme.semanticWarning : HisingenTheme.ink)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel({
            var label = warning || valueWarning ? "\(L10n.text("Warning")): \(key), \(value)" : "\(key): \(value)"
            if let info { label += ". \(info)" }
            return label
        }())
    }
}

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


    private var isPolestar: Bool { Preferences.appTheme == .polestar }
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
        .onChange(of: isCharging) { charging in
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


