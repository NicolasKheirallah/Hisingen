import SwiftUI

private struct ScrollRevealActionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var scrollRevealAction: @MainActor @Sendable (String) -> Void {
        get { self[ScrollRevealActionKey.self] }
        set { self[ScrollRevealActionKey.self] = newValue }
    }
}

@MainActor
struct WholeRowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // A disclosure opening re-lays-out everything below it, so it is a layout change
                // and takes the layout token. `interaction` is for the press itself, and a spring
                // tuned for a 0.2 s acknowledgement rings on a full-height expansion.
                withAnimation(reduceMotion ? nil : Motion.layout) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .hisType(.label, weight: .semibold)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
