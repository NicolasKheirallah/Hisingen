import SwiftUI

struct KVRow: View {
    let key: String
    let value: String
    let symbol: String?
    let valueWarning: Bool
    let warning: Bool


    let info: String?
    init(_ key: String, _ value: String, symbol: String? = nil, valueWarning: Bool = false, warning: Bool = false, info: String? = nil) {
        self.key = key
        self.value = value
        self.symbol = symbol
        self.valueWarning = valueWarning
        self.warning = warning
        self.info = info
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(warning ? HisingenTheme.semanticWarning : .secondary)
                    .accessibilityHidden(true)
            }
            Text(key)
                .foregroundStyle(warning ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
                .font(.system(size: 12, weight: .regular))
            if let info {
                InformationButton(message: info)
            }
            Spacer()
            Text(value)
                .foregroundStyle(valueWarning ? HisingenTheme.semanticWarning : HisingenTheme.ink)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
        .accessibilityElement(children: info == nil ? .ignore : .contain)
        .accessibilityLabel({
            var label = warning || valueWarning ? "\(L10n.text("Warning")): \(key), \(value)" : "\(key): \(value)"
            if let info { label += ". \(info)" }
            return label
        }())
    }
}
