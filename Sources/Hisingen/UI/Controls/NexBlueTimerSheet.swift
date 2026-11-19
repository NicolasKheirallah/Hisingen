import SwiftUI

@MainActor
struct NexBlueTimerSheet: View {
    @ObservedObject var model: HomeChargingModel
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 3
    @State private var preview: NexBlueTimerPreview?
    @State private var failure: String?
    @State private var busy = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Cheapest overnight charge"))
                .hisType(.displaySmall, weight: HisingenTheme.headingWeight)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.format("Find a one-time charging window between %@ and %@ using your selected spot price area.",
                             Format.clockTime(hour: 18), Format.clockTime(hour: 7)))
                .hisType(.body)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            PanelRule()
            Picker(L10n.text("Duration"), selection: $hours) {
                ForEach(1...8, id: \.self) { hours in
                    Text(Duration.seconds(hours * 3_600).formatted(.units(allowed: [.hours], width: .abbreviated)
                        .locale(L10n.displayLocale)))
                        .tag(hours)
                }
            }
            .disabled(busy || saved)
            .onChange(of: hours) { _, _ in preview = nil; failure = nil }
            if let preview {
                Text(HomeChargingTime.range(preview.window, in: preview.schedule.timeZone))
                    .hisType(.title, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(preview.zone.title) · \(preview.schedule.timeZone.identifier)")
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            if let failure {
                Text(failure)
                    .hisType(.body)
                    .foregroundStyle(HisingenTheme.semanticCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if saved {
                Text(L10n.text("Timer verified on the charger. You can manage it in myNexBlue."))
                    .hisType(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(saved ? L10n.text("Done") : L10n.text("Cancel")) { dismiss() }
                    .buttonStyle(.hisSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(preview == nil ? L10n.text("Preview timer") : L10n.text("Save timer"))
                }
                if !saved {
                    Button(preview == nil ? L10n.text("Preview timer") : L10n.text("Save timer")) {
                        Task { await advance() }
                    }
                    .buttonStyle(.hisProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || model.link != .live)
                }
            }
        }
        .foregroundStyle(HisingenTheme.ink)
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .background(HisingenTheme.canvas)
        .interactiveDismissDisabled(busy)
    }

    private func advance() async {
        guard !busy, !saved else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            if let preview {
                try await model.saveNexBlueTimer(preview)
                saved = true
            } else {
                preview = try await model.previewNexBlueTimer(hours: hours)
            }
        } catch {
            preview = nil
            failure = error.localizedDescription
        }
    }
}
