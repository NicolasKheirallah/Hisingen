import SwiftUI

/// The primary button: a solid fill with its label in the theme canvas colour.
///
/// It replaces `.borderedProminent`, which always draws a white label. In dark appearance every
/// theme's accent and status colours are light, so white on them measured about 2:1. The canvas
/// is what each fill is already gated against (4.5:1 for accent and status text on the canvas,
/// and contrast is symmetric), so canvas-on-fill holds in every theme and appearance.
struct HisProminentButtonStyle: ButtonStyle {
    var fill: Color = HisingenTheme.accent

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .hisType(controlSize == .large ? .body : .label, weight: .semibold)
            .foregroundStyle(isEnabled ? HisingenTheme.canvas : HisingenTheme.inkMuted)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background(shape.fill(isEnabled ? fill : HisingenTheme.chipFill))
            .overlay {
                if isEnabled && (hovering || configuration.isPressed) {
                    shape.fill(HisingenTheme.canvas.opacity(configuration.isPressed ? 0.18 : 0.10))
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .hisAnimation(Motion.interaction, value: hovering)
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: return 9
        case .large, .extraLarge: return 16
        default: return 12
        }
    }

    private var minHeight: CGFloat {
        switch controlSize {
        case .mini: return 18
        case .small: return 22
        case .large, .extraLarge: return 34
        default: return 28
        }
    }
}

extension ButtonStyle where Self == HisProminentButtonStyle {
    static var hisProminent: HisProminentButtonStyle { HisProminentButtonStyle() }
    static func hisProminent(_ fill: Color) -> HisProminentButtonStyle { HisProminentButtonStyle(fill: fill) }
}

/// The secondary button: label in ink (or a status colour when the action carries one) on the
/// solid chip fill, with a hairline edge.
///
/// It replaces `.bordered`, whose bezel takes its fill from the tint: in dark appearance a light
/// accent turned the bezel light grey under a light label, and amber-on-wash read as faint brown
/// in light. The chip fill is the inset surface every label colour is already checked against.
/// Hover and press darken the fill a step; disabled drops to muted ink.
struct HisSecondaryButtonStyle: ButtonStyle {
    var tint: Color? = nil

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .hisType(controlSize == .large ? .body : .label, weight: .semibold)
            .foregroundStyle(isEnabled ? (tint ?? HisingenTheme.ink) : HisingenTheme.inkMuted)
            .padding(.horizontal, controlSize == .small || controlSize == .mini ? 9 : 12)
            .frame(minHeight: controlSize == .small || controlSize == .mini ? 22 : 28)
            .background(shape.fill(HisingenTheme.chipFill))
            .overlay {
                if isEnabled && (hovering || configuration.isPressed) {
                    shape.fill(HisingenTheme.ink.opacity(configuration.isPressed ? 0.10 : HisingenTheme.chipHoverFill))
                }
            }
            .overlay(shape.stroke(HisingenTheme.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.7)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .hisAnimation(Motion.interaction, value: hovering)
    }
}

extension ButtonStyle where Self == HisSecondaryButtonStyle {
    static var hisSecondary: HisSecondaryButtonStyle { HisSecondaryButtonStyle() }
    static func hisSecondary(_ tint: Color?) -> HisSecondaryButtonStyle { HisSecondaryButtonStyle(tint: tint) }
}
