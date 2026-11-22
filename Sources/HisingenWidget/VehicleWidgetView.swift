import SwiftUI

/// The widget reads DESIGN.md the same way the panel does: flat canvas, one typeface, a
/// figure over its muted label, hairline row dividers, and the 2pt charge line. The system
/// face is Helvetica Neue on macOS, so plain `.system` fonts are the panel's own face.
///
/// The live colour is the amber of the base Monochrome Precision palette (whose accent is
/// ink) rather than a themed accent: a reader's theme lives in the app's database, which
/// the widget's container does not carry. See docs/development/widgets-and-controls.md.
private enum WidgetPalette {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0, green: 0, blue: 0) : Color(red: 1, green: 1, blue: 1)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1, green: 1, blue: 1) : Color(red: 0, green: 0, blue: 0)
    }

    /// #666666 on white (5.7:1), #999999 on black (7.4:1).
    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.6, green: 0.6, blue: 0.6)
            : Color(red: 0.4, green: 0.4, blue: 0.4)
    }

    /// Amber, the live colour of the base palette: #B5770F on white (3.7:1 as a graphic),
    /// #E8A93A on black (10.1:1).
    static func live(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.91, green: 0.663, blue: 0.227)
            : Color(red: 0.71, green: 0.467, blue: 0.059)
    }
}

/// One figure over one muted label: the spec grammar every surface in the app shares.
private struct FigureOverLabel: View {
    let figure: String
    let label: String
    var size: CGFloat = 26
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(figure)
                .font(.system(size: size))
                .tracking(-0.036 * size)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(WidgetPalette.muted(colorScheme))
        }
        .foregroundStyle(WidgetPalette.ink(colorScheme))
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// The 2pt charge line beside the charging state's own words. Gold while energy moves,
/// ink at rest, exactly as the panel draws it.
private struct ChargingLine: View {
    let text: String
    let isLive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(isLive ? WidgetPalette.live(colorScheme) : WidgetPalette.ink(colorScheme))
                .frame(width: 14, height: 2)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(WidgetPalette.ink(colorScheme))
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// A 12 % ink hairline, the row divider the panel uses.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(WidgetPalette.ink(colorScheme).opacity(0.12))
            .frame(height: 1)
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// The widget body for both shipped families. Everything on screen was resolved by the
/// app; this view only places the strings and re-derives the age line.
struct VehicleWidgetEntryView: View {
    let entry: VehicleWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) { WidgetPalette.canvas(colorScheme) }
            .widgetURL(entry.link)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    /// The line under the title: the reading age when data is on file, the placeholder
    /// sentence when it is not.
    private var statusLine: String? {
        if let checked = entry.checkedLine { return checked }
        guard entry.snapshot == nil else { return nil }
        return WidgetL10n.text("No vehicle data yet", languageCode)
    }

    /// The muted note under the status line when the configured car is missing and the
    /// active car stands in. Only the substitution names a different car than the one the
    /// reader chose, so this is the only place the widget says so.
    private var fallbackNoteLine: String? { entry.fallbackNote }

    private func mutedLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(WidgetPalette.muted(colorScheme))
    }

    // MARK: systemSmall

    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            if let status = statusLine {
                mutedLine(status)
            }
            if let note = fallbackNoteLine {
                mutedLine(note)
            }
            Spacer(minLength: 0)
            FigureOverLabel(figure: batteryFigure, label: batteryLabel)
            Spacer(minLength: 0)
            if let charging = chargingText {
                ChargingLine(text: charging, isLive: isChargingLive)
            }
        }
    }

    // MARK: systemMedium

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                titleRow
                Spacer(minLength: 8)
                if let status = statusLine {
                    mutedLine(status)
                }
            }
            if let note = fallbackNoteLine {
                mutedLine(note)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 14) {
                FigureOverLabel(figure: batteryFigure, label: batteryLabel)
                if let range = entry.snapshot?.rangeText {
                    FigureOverLabel(figure: range, label: rangeLabel)
                }
                Spacer(minLength: 0)
                if let departure = entry.snapshot?.departureText {
                    FigureOverLabel(figure: departure, label: departureLabel, size: 15, alignment: .trailing)
                }
            }
            Hairline()
            if let charging = chargingText {
                ChargingLine(text: charging, isLive: isChargingLive)
            }
        }
    }

    // MARK: shared pieces

    /// The vehicle title, or the app's own name when nothing is on file yet.
    private var titleRow: some View {
        Text(entry.snapshot?.name ?? "Hisingen")
            .font(.system(size: 14))
            .lineLimit(1)
            .foregroundStyle(WidgetPalette.ink(colorScheme))
    }

    private var batteryFigure: String { entry.snapshot?.batteryText ?? "–" }
    private var isChargingLive: Bool {
        entry.snapshot?.charging?.isLive ?? false
    }
    private var chargingText: String? {
        guard let snapshot = entry.snapshot else { return nil }
        return snapshot.chargingText
    }
    private var languageCode: String? { entry.snapshot?.languageCode }

    private var batteryLabel: String { WidgetL10n.text("Battery", languageCode) }
    private var rangeLabel: String { WidgetL10n.text("Estimated Range", languageCode) }
    private var departureLabel: String { WidgetL10n.text("Departure", languageCode) }

    private var accessibilitySummary: String {
        guard let snapshot = entry.snapshot else {
            return WidgetL10n.text("No vehicle data yet", nil)
        }
        var parts = [snapshot.name]
        if let battery = snapshot.batteryText { parts.append(battery) }
        if let charging = snapshot.chargingText { parts.append(charging) }
        if let departure = snapshot.departureText { parts.append(departure) }
        if let checked = entry.checkedLine { parts.append(checked) }
        if let note = entry.fallbackNote { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}
