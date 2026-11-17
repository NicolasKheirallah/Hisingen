import SwiftUI

@MainActor
struct NexBlueHistorySheet: View {
    @ObservedObject var model: HomeChargingModel
    let timeZone: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var through: Date
    @State private var importing = false

    init(model: HomeChargingModel, timeZone: TimeZone) {
        self.model = model
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: model.clock)
        _start = State(initialValue: calendar.date(byAdding: .day, value: -29, to: today) ?? today)
        _through = State(initialValue: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Import earlier sessions"))
                .hisType(.displaySmall, weight: HisingenTheme.headingWeight)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("Choose up to one year of completed sessions to import."))
                .hisType(.body)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            PanelRule()
            DatePicker(L10n.text("From"), selection: $start, in: ...through, displayedComponents: .date)
                .disabled(importing)
            DatePicker(L10n.text("Through"), selection: $through, in: start...max(start, calendar.startOfDay(for: model.clock)),
                       displayedComponents: .date)
                .disabled(importing)
            if case .failed(let message) = model.syncState {
                Text(message)
                    .hisType(.body)
                    .foregroundStyle(HisingenTheme.semanticCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("Cancel")) { dismiss() }
                    .buttonStyle(.hisSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(importing)
                Spacer(minLength: 8)
                if importing { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("Importing")) }
                Button(L10n.text("Import sessions now")) {
                    guard let range, !importing else { return }
                    importing = true
                    Task {
                        await model.syncSessions(backfill: range)
                        importing = false
                        if case .finished(let summary) = model.syncState, !summary.skippedByPrivacy { dismiss() }
                    }
                }
                .buttonStyle(.hisProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importing || !model.canBackfillNexBlue || range == nil)
            }
        }
        .foregroundStyle(HisingenTheme.ink)
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .background(HisingenTheme.canvas)
        .environment(\.timeZone, timeZone)
        .interactiveDismissDisabled(importing)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var range: DateInterval? {
        guard let followingDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)) else { return nil }
        let from = calendar.startOfDay(for: start)
        let to = min(followingDay, model.clock)
        guard to > from, to.timeIntervalSince(from) <= HomeChargingModel.maxNexBlueBackfill else { return nil }
        return DateInterval(start: from, end: to)
    }
}
