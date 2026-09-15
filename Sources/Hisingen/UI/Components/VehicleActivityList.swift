import SwiftUI

struct VehicleActivityList: View {
    let events: [VehicleActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // With no events this rendered the footnote and nothing else, which reads as content
            // that failed to load above it rather than as an empty list.
            if events.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(L10n.text("Nothing has changed while Hisingen was running."))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .hisCaptionLeading()
            }
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.title).font(.caption.weight(.semibold))
                        Spacer()
                        Text(event.timestamp, style: .date).font(.caption2).foregroundStyle(.secondary)
                        Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(event.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L10n.text("Observed changes while Hisingen was running. Software times indicate when a version change was first seen."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
