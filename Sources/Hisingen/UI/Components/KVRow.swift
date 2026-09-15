import SwiftUI

struct KVRow: View {
    let key: String
    let value: String
    let symbol: String?
    let valueWarning: Bool
    let warning: Bool
    /// A critical row outranks a warning one. Both rendered in `semanticWarning`, so a triggered
    /// alarm looked exactly like a low washer-fluid level: same size, same colour, same symbol
    /// family, in whatever order the data arrived.
    let critical: Bool


    let info: String?
    init(_ key: String, _ value: String, symbol: String? = nil, valueWarning: Bool = false, warning: Bool = false, critical: Bool = false, info: String? = nil) {
        self.key = key
        self.value = value
        self.symbol = symbol
        self.valueWarning = valueWarning
        self.warning = warning
        self.critical = critical
        self.info = info
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .hisType(.label, weight: .medium)
                    .foregroundStyle(critical ? HisingenTheme.semanticCritical
                                              : (warning ? HisingenTheme.semanticWarning : .secondary))
                    .accessibilityHidden(true)
            }
            Text(key)
                .foregroundStyle(critical ? HisingenTheme.semanticCritical
                                          : (warning ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted))
                .hisType(.body, weight: .regular)
            if let info {
                InformationButton(message: info, subject: key)
            }
            Spacer()
            Text(value)
                .foregroundStyle(critical ? HisingenTheme.semanticCritical
                                          : (valueWarning ? HisingenTheme.semanticWarning : HisingenTheme.ink))
                .hisType(.body, weight: HisingenTheme.valueWeight)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
                .hisTelemetryValue(value, reduceMotion: reduceMotion)
        }
        .hisAnimation(Motion.stateChange, value: warning)
        .hisAnimation(Motion.stateChange, value: critical)
        .hisAnimation(Motion.stateChange, value: valueWarning)
        .accessibilityElement(children: info == nil ? .ignore : .contain)
        .accessibilityLabel({
            let severity = critical ? L10n.text("Critical")
                : ((warning || valueWarning) ? L10n.text("Warning") : nil)
            var label = severity.map { "\($0): \(key), \(value)" } ?? "\(key): \(value)"
            if let info { label += ". \(info)" }
            return label
        }())
    }
}
