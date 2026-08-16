import SwiftUI

/// Top-down cabin blueprint: front seat heating levels, LHD/RHD-aware steering
/// wheel placement, rear bench outline, comfort target, and CleanZone status.
@MainActor
struct CabinSeatingMatrixView: View {
    let isRightHandDrive: Bool
    let driverSeatHeatingLevel: Int
    let passengerSeatHeatingLevel: Int
    let steeringWheelHeatingLevel: Int
    let targetTemperatureCelsius: Double?
    let isAirPurifying: Bool

    private let fixedHeight: CGFloat = 176

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let driverY = isRightHandDrive ? h * 0.78 : h * 0.22
            let passengerY = h - driverY

            ZStack {
                CabinOutlineShape()
                    .fill(HisingenTheme.canvas.opacity(0.5))
                CabinOutlineShape()
                    .stroke(HisingenTheme.hairline, lineWidth: 1.5)

                CleanZoneIndicator(isActive: isAirPurifying)
                    .position(x: w * 0.09, y: h * 0.5)

                SteeringWheelBadge(heatLevel: steeringWheelHeatingLevel, diameter: h * 0.24)
                    .position(x: w * 0.27, y: driverY)

                ClimateTargetBadge(temperature: targetTemperatureCelsius)
                    .position(x: w * 0.5, y: h * 0.5)

                SeatBlock(
                    symbol: "carseat.left.fill",
                    label: nil,
                    heatLevel: driverSeatHeatingLevel,
                    width: w * 0.15,
                    height: h * 0.46
                )
                .position(x: w * 0.34, y: driverY)

                SeatBlock(
                    symbol: "carseat.right.fill",
                    label: nil,
                    heatLevel: passengerSeatHeatingLevel,
                    width: w * 0.15,
                    height: h * 0.46
                )
                .position(x: w * 0.34, y: passengerY)

                SeatBlock(
                    symbol: "carseat.left.fill",
                    label: L10n.text("Rear Left"),
                    heatLevel: nil,
                    width: w * 0.13,
                    height: h * 0.30
                )
                .position(x: w * 0.75, y: h * 0.18)

                SeatBlock(
                    symbol: "chair.fill",
                    label: L10n.text("Rear Center"),
                    heatLevel: nil,
                    width: w * 0.13,
                    height: h * 0.30
                )
                .position(x: w * 0.75, y: h * 0.5)

                SeatBlock(
                    symbol: "carseat.right.fill",
                    label: L10n.text("Rear Right"),
                    heatLevel: nil,
                    width: w * 0.13,
                    height: h * 0.30
                )
                .position(x: w * 0.75, y: h * 0.82)
            }
            .frame(width: w, height: h)
        }
        .frame(maxWidth: .infinity, minHeight: fixedHeight, maxHeight: fixedHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [
            L10n.text("Cabin Seating Matrix"),
            "\(L10n.text("Driver Seat Heating")): \(CabinHeatPalette.label(for: driverSeatHeatingLevel))",
            "\(L10n.text("Passenger Seat Heating")): \(CabinHeatPalette.label(for: passengerSeatHeatingLevel))",
            "\(L10n.text("Steering Wheel Heating")): \(CabinHeatPalette.label(for: steeringWheelHeatingLevel))",
            targetTemperatureCelsius.map { "\(L10n.text("Comfort Target")): \(String(format: "%.1f°C", $0))" } ?? "",
            L10n.text(isAirPurifying ? "Active Purifying" : "CleanZone Ready")
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
    }
}

private enum CabinHeatPalette {
    static func color(for level: Int) -> Color {
        switch level {
        case 1: return Color(red: 1.0, green: 0.72, blue: 0.35)
        case 2: return Color(red: 1.0, green: 0.55, blue: 0.15)
        case 3...: return Color(red: 0.95, green: 0.35, blue: 0.05)
        default: return Color.secondary.opacity(0.18)
        }
    }

    static func label(for level: Int) -> String {
        level > 0 ? "L\(level)" : L10n.text("Off")
    }
}

private struct CabinOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let noseChamfer = rect.width * 0.10
        let tailChamfer = rect.width * 0.045

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + noseChamfer))
        p.addLine(to: CGPoint(x: rect.minX + noseChamfer * 0.7, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tailChamfer, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tailChamfer))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tailChamfer))
        p.addLine(to: CGPoint(x: rect.maxX - tailChamfer, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + noseChamfer * 0.7, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - noseChamfer))
        p.closeSubpath()
        return p
    }
}

private struct SeatBlock: View {
    let symbol: String
    let label: String?
    let heatLevel: Int?
    let width: CGFloat
    let height: CGFloat

    private var isHeated: Bool { (heatLevel ?? 0) > 0 }

    var body: some View {
        let radius = min(width, height) * 0.24
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(HisingenTheme.canvas)
            if let heatLevel, heatLevel > 0 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [CabinHeatPalette.color(for: heatLevel).opacity(0.85), CabinHeatPalette.color(for: heatLevel).opacity(0.20)],
                            center: .center,
                            startRadius: 1,
                            endRadius: max(width, height) * 0.7
                        )
                    )
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(HisingenTheme.hairline, lineWidth: 1)

            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: min(width, height) * 0.30, weight: .medium))
                    .foregroundStyle(isHeated ? Color.orange : HisingenTheme.inkMuted)
                if let heatLevel {
                    Text(CabinHeatPalette.label(for: heatLevel))
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(isHeated ? CabinHeatPalette.color(for: heatLevel) : Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(isHeated ? Color.white : HisingenTheme.inkMuted)
                } else if let label {
                    Text(label)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(width: width, height: height)
    }
}

private struct SteeringWheelBadge: View {
    let heatLevel: Int
    let diameter: CGFloat

    private var isHeated: Bool { heatLevel > 0 }

    var body: some View {
        ZStack {
            Circle().fill(HisingenTheme.canvas)
            if isHeated {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [CabinHeatPalette.color(for: heatLevel).opacity(0.9), CabinHeatPalette.color(for: heatLevel).opacity(0.15)],
                            center: .center,
                            startRadius: 1,
                            endRadius: diameter * 0.6
                        )
                    )
            }
            Circle().stroke(HisingenTheme.hairline, lineWidth: 1)
            Image(systemName: "steeringwheel")
                .font(.system(size: diameter * 0.46, weight: .semibold))
                .foregroundStyle(isHeated ? Color.orange : HisingenTheme.inkMuted)
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct CleanZoneIndicator: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private let diameter: CGFloat = 22

    var body: some View {
        ZStack {
            if isActive && !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(HisingenTheme.accent.opacity(0.45 - Double(i) * 0.18), lineWidth: 1.4)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(pulse ? 2.0 + CGFloat(i) * 0.4 : 1.0)
                        .opacity(pulse ? 0 : 0.9)
                }
            }
            Circle().fill(HisingenTheme.canvas).frame(width: diameter, height: diameter)
            Circle().stroke(HisingenTheme.hairline, lineWidth: 1).frame(width: diameter, height: diameter)
            Image(systemName: "wind")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? HisingenTheme.accent : HisingenTheme.inkMuted)
        }
        .onAppear {
            guard isActive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct ClimateTargetBadge: View {
    let temperature: Double?

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HisingenTheme.accent)
            Text(temperature.map { String(format: "%.1f°", $0) } ?? "—")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(temperature != nil ? HisingenTheme.ink : HisingenTheme.inkMuted)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(HisingenTheme.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(HisingenTheme.hairline, lineWidth: 1))
    }
}
