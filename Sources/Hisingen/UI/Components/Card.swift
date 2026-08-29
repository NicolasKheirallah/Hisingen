import SwiftUI
import AppKit

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
                // A quiet breath, not a throb: a ~6 % swell on a slow cycle.
                .scaleEffect(isPulsing && pulse ? 1.06 : 1.0)
                .shadow(color: isPulsing && pulse ? color.opacity(0.45) : .clear, radius: 3)
                .animation(
                    isPulsing && !reduceMotion ? Motion.breath : .default,
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}
