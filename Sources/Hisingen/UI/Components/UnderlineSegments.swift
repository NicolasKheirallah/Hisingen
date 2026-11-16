import SwiftUI

/// A single-choice filter drawn as polestar.com draws its sub-navigation: plain labels on a
/// hairline, the chosen one in ink with a 2pt underline. Each option is a button with the
/// selected trait, so VoiceOver reads it as the same choice the segmented control offered.
struct UnderlineSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(options, id: \.value) { option in
                    let selected = option.value == selection
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.selection) { selection = option.value }
                    } label: {
                        Text(option.title)
                            .hisType(.subhead)
                            .lineLimit(1)
                            .foregroundStyle(selected ? HisingenTheme.ink : HisingenTheme.inkMuted)
                            .frame(minHeight: 32)
                            .overlay(alignment: .bottom) {
                                if selected {
                                    Rectangle()
                                        .fill(HisingenTheme.ink)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "segment", in: underline)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.never)
        .background(alignment: .bottom) { PanelRule() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
