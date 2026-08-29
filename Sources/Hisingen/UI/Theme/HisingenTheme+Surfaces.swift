import SwiftUI
import AppKit

@MainActor
extension HisingenTheme {

    // MARK: - Card Surface

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

    // MARK: - Popover Surface

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
}
