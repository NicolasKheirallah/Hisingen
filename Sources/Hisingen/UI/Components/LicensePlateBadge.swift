import SwiftUI

struct LicensePlateBadge: View {
    let plate: String
    let style: RegistrationNumberBadgePosition
    let showsSwedishFlag: Bool

    var body: some View {
        switch style {
        case .platePill:
            HStack(spacing: 4) {
                swedishFlag
                plateText(size: 11, tracking: 1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.8)
            )
        case .belowGreeting, .inlineHeader:
            // `Text.monospaced()` monospaces digits only, so "ABC 123" kept proportional letters
            // here while the pill and overlay positions monospaced the whole string. `plateText`
            // monospaces the plate, which is what a plate is.
            plateText(size: 13, tracking: 0.4)
        case .topRightOverlay, .topLeftOverlay:
            HStack(spacing: 4) {
                swedishFlag
                plateText(size: 10.5, tracking: 0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(HisingenTheme.chipFill, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6))
            .shadow(color: HisingenTheme.shadowTint(0.08), radius: 4, x: 0, y: 1.5)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var swedishFlag: some View {
        if showsSwedishFlag {
            Text("🇸🇪").hisType(.micro)
        }
    }

    private func plateText(size: CGFloat, tracking: CGFloat) -> some View {
        Text(plate.uppercased())
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(tracking)
            .foregroundStyle(HisingenTheme.ink)
    }
}
