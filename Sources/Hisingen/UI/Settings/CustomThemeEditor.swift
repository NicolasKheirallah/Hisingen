import AppKit
import SwiftUI

/// Makes or edits a reader's own theme: a name and three colours, with a live preview of what
/// the panel will draw in light and dark once contrast has been applied.
@MainActor
struct CustomThemeEditor: View {
    @State private var draft: CustomThemeDefinition
    let isNew: Bool
    let onSave: (CustomThemeDefinition) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var confirmingDelete = false

    init(definition: CustomThemeDefinition, isNew: Bool,
         onSave: @escaping (CustomThemeDefinition) -> Void,
         onDelete: (() -> Void)?,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: definition)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    private var colors: CustomThemeColors { CustomThemeColors.resolve(draft) }

    private func binding(_ keyPath: WritableKeyPath<CustomThemeDefinition, String>) -> Binding<Color> {
        Binding(
            get: { ThemeRGB(hex: draft[keyPath: keyPath]).map { Color(nsColor: $0.nsColor) } ?? .gray },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                draft[keyPath: keyPath] = ThemeRGB(r: Double(srgb.redComponent), g: Double(srgb.greenComponent),
                                                   b: Double(srgb.blueComponent)).hex
            }
        )
    }

    var body: some View {
        let resolved = colors
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? L10n.text("Create Theme") : L10n.text("Edit Theme"))
                .hisType(.displaySmall)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Name"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                HisTextField(L10n.text("My Theme"), text: $draft.name)
                    .accessibilityLabel(L10n.text("Name"))
            }

            VStack(spacing: 0) {
                colorRow(L10n.text("Accent"), binding(\.accentHex))
                colorRow(L10n.text("Light Background"), binding(\.lightBackgroundHex))
                colorRow(L10n.text("Dark Background"), binding(\.darkBackgroundHex))
            }

            HStack(spacing: 8) {
                ThemePreviewTile(canvas: resolved.canvasLight, ink: resolved.inkLight,
                                 muted: resolved.mutedLight, accent: resolved.accentLight,
                                 title: L10n.text("Light"))
                ThemePreviewTile(canvas: resolved.canvasDark, ink: resolved.inkDark,
                                 muted: resolved.mutedDark, accent: resolved.accentDark,
                                 title: L10n.text("Dark"))
            }

            Text(L10n.text("Your colours, adjusted to stay readable in light and dark."))
                .hisType(.caption)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let onDelete {
                    Button(L10n.text("Delete"), role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
                        .confirmationDialog(L10n.text("Delete"), isPresented: $confirmingDelete) {
                            Button(L10n.text("Delete"), role: .destructive) { onDelete() }
                            Button(L10n.text("Cancel"), role: .cancel) {}
                        } message: {
                            Text(draft.name)
                        }
                }
                Spacer()
                Button(L10n.text("Cancel"), action: onCancel)
                    .buttonStyle(.hisSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Save")) { onSave(draft) }
                    .buttonStyle(.hisProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(HisingenTheme.canvas)
    }

    private func colorRow(_ title: String, _ color: Binding<Color>) -> some View {
        HStack {
            Text(title)
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.ink)
            Spacer()
            ColorPicker(title, selection: color, supportsOpacity: false)
                .labelsHidden()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { PanelRule() }
    }
}

/// A miniature of the panel in one appearance: a figure, its label, a primary action and an
/// active control, drawn in the exact colours the theme resolves to.
private struct ThemePreviewTile: View {
    let canvas: ThemeRGB
    let ink: ThemeRGB
    let muted: ThemeRGB
    let accent: ThemeRGB
    let title: String

    private func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }
    private var accentText: ThemeRGB { accent.contrast(with: canvas) >= 4.5 ? canvas : ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .hisType(.label)
                .foregroundStyle(color(muted))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("72")
                    .hisType(size: 26, relativeTo: .title)
                    .foregroundStyle(color(ink))
                Text("%")
                    .hisType(.label)
                    .foregroundStyle(color(muted))
            }
            Text(L10n.text("Battery"))
                .hisType(.label)
                .foregroundStyle(color(muted))
            Text(L10n.text("Heating"))
                .hisType(.label)
                .foregroundStyle(color(accentText))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(accent))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(canvas))
        .overlay(Rectangle().strokeBorder(HisingenTheme.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
