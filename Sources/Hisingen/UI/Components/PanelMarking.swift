import SwiftUI

struct PanelDatum: View {
    var color: Color = HisingenTheme.inkMuted

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 14, height: 2)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct PanelRule: View {
    var body: some View {
        Rectangle()
            .fill(HisingenTheme.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct VehicleStudio<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .background(HisingenTheme.palette.studioFill)
    }
}
