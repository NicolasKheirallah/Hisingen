import SwiftUI

/// A text entry drawn as a spec line: the value on the canvas over a rule, with no box and no
/// corners. The rule rests in the muted ink (the 12 % hairline is too faint to mark an input at
/// 3:1) and takes the 2pt ink underline while the field has focus, the same mark the tabs and
/// the segmented rows use for a chosen place. It replaces the system focus ring, so keyboard
/// focus stays visible.
///
/// The placeholder is drawn here, in the muted ink. The system draws a plain field's own
/// prompt in a dark grey that reads as a value somebody already typed, and it ignores a styled
/// `prompt:`. A field with a placeholder is built with ``HisTextField`` or ``HisSecureField``.
struct HisFieldStyle: ViewModifier {
    var placeholder = ""
    var isEmpty = false
    var label: String?

    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .hisType(.body)
            .padding(.vertical, 6)
            .overlay(alignment: .leading) {
                if isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .hisType(.body)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? HisingenTheme.ink : HisingenTheme.inkMuted)
                    .frame(height: focused ? 2 : 1)
                    .opacity(isEnabled ? 1 : 0.5)
                    .accessibilityHidden(true)
            }
            .hisFieldLabel(label ?? placeholder)
    }
}

extension View {
    /// Names the field for VoiceOver unless there is nothing to say: an empty label would
    /// replace the one the field already has.
    @ViewBuilder
    fileprivate func hisFieldLabel(_ text: String) -> some View {
        if text.isEmpty { self } else { accessibilityLabel(text) }
    }

    /// Draws a `TextField` or `SecureField` as a ruled spec line. See ``HisFieldStyle``.
    func hisField() -> some View {
        modifier(HisFieldStyle())
    }
}

/// A ruled text field with a muted placeholder. `label` names the field for VoiceOver when the
/// placeholder is only an example ("name@example.com") or empty.
struct HisTextField: View {
    let placeholder: String
    @Binding var text: String
    var label: String?

    init(_ placeholder: String, text: Binding<String>, label: String? = nil) {
        self.placeholder = placeholder
        _text = text
        self.label = label
    }

    var body: some View {
        TextField("", text: $text)
            .modifier(HisFieldStyle(placeholder: placeholder, isEmpty: text.isEmpty, label: label))
    }
}

/// The secure counterpart of ``HisTextField``.
struct HisSecureField: View {
    let placeholder: String
    @Binding var text: String
    var label: String?

    init(_ placeholder: String, text: Binding<String>, label: String? = nil) {
        self.placeholder = placeholder
        _text = text
        self.label = label
    }

    var body: some View {
        SecureField("", text: $text)
            .modifier(HisFieldStyle(placeholder: placeholder, isEmpty: text.isEmpty, label: label))
    }
}
