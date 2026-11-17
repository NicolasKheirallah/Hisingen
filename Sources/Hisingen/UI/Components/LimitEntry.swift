import SwiftUI

/// What a limit card needs to let the reader type a value instead of stepping to it.
struct LimitEntry {
    let title: String
    let unit: String
    let range: ClosedRange<Int>
    let current: Int?
    let rangeText: String
    let command: (Int) -> RemoteCommand
}

/// A small pencil at the foot of a limit card. The card itself is one button that steps the limit,
/// so typing sits beside it, never inside it: this is a separate control with its own label, focus
/// stop and popover. The field takes digits only, shows the range the car allows, and Save stays off
/// until the number is inside it.
struct LimitEntryButton: View {
    let entry: LimitEntry
    let isAvailable: Bool
    let color: Color
    let send: (RemoteCommand) -> Void

    @State private var presented = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var value: Int? { LimitStepping.entry(text, within: entry.range) }

    var body: some View {
        Button {
            text = entry.current.map(String.init) ?? ""
            presented = true
        } label: {
            Image(systemName: "pencil")
                .hisSymbolSize(11)
                .foregroundStyle(color)
        }
        .buttonStyle(.pressable)
        .disabled(!isAvailable)
        .help(L10n.text("Type a value"))
        .accessibilityLabel(L10n.text("Type a value"))
        .accessibilityValue(entry.title)
        .popover(isPresented: $presented, arrowEdge: .bottom) { form }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title)
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.inkMuted)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .hisType(.displaySmall)
                        .monospacedDigit()
                        .frame(width: 72)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: text) { _, new in
                            let digits = String(new.filter { $0 >= "0" && $0 <= "9" }.prefix(3))
                            if digits != new { text = digits }
                        }
                        .accessibilityLabel(entry.title)
                    Text(entry.unit)
                        .hisType(.body)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                PanelRule()
            }
            Text(entry.rangeText)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
            HStack(spacing: 8) {
                Button(L10n.text("Cancel")) { presented = false }
                    .buttonStyle(.hisSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Save"), action: commit)
                    .buttonStyle(.hisProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value == nil)
            }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear { focused = true }
    }

    private func commit() {
        guard let value else { return }
        presented = false
        if value != entry.current { send(entry.command(value)) }
    }
}
