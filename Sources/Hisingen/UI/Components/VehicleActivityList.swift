import SwiftUI

struct VehicleActivityList: View {
    let events: [VehicleActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
