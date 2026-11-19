import SwiftUI

/// Plan's opening answer: when the car is leaving, and whether charging will be done by then.
///
/// The time is the car's next reported departure. With none reported, the reader can pick a time
/// to check against; that choice stays in the panel and is never sent to the car.
@MainActor
struct PlanDeparture: View {
    let state: VehicleState

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var checkedDeparture: Date?

    private var scheduledDeparture: Date? {
        PlanTimeline.entries(for: state).first { $0.schedule.kind == .departure }?.next
    }

    private var departure: Binding<Date> {
        Binding(get: { checkedDeparture ?? scheduledDeparture ?? Date().addingTimeInterval(3_600) },
                set: { checkedDeparture = $0 })
    }

    static func dayText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.text("Today") }
        if calendar.isDateInTomorrow(date) { return L10n.text("Tomorrow") }
        return Format.dateFormatter.string(from: date)
    }

    var body: some View {
        let when = departure.wrappedValue
        let assessment = VehicleReadiness.assessDeparture(state, departure: when)
        let reported = scheduledDeparture != nil && checkedDeparture == nil
        VStack(alignment: .leading, spacing: 6) {
            Text(reported ? L10n.text("Departure") : L10n.text("Check charging before departure"))
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.inkMuted)
                .accessibilityAddTraits(.isHeader)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 14))
            layout {
                Text(Format.timeFormatter.string(from: when))
                    .hisType(size: 44, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.ink)
                    .contentTransition(.numericText())
                Text(Self.dayText(when))
                    .hisType(.subhead)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Spacer(minLength: 0)
                DatePicker(L10n.text("Departure"), selection: departure, in: Date()...,
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .fixedSize()
            }
            if let destination = assessment.estimateDestination {
                Text(destination)
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            Text(assessment.message)
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The next 24 hours on one hairline ruler: charging windows as gold bands (solid while the car
/// charges), climate timers as ink marks, departure as a tick. A picture of the schedule list
/// below it, so it carries no controls of its own.
@MainActor
struct PlanDayTimeline: View {
    let state: VehicleState
    var now: Date = Date()

    private static let span: TimeInterval = 24 * 3_600

    struct Band: Hashable { let start: CGFloat; let end: CGFloat; let live: Bool }
    struct Mark: Hashable { let at: CGFloat; let kind: ScheduleKind }

    private var entries: [PlanTimeline.Entry] { PlanTimeline.entries(for: state, now: now) }

    private func fraction(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(now) / Self.span, 0), 1))
    }

    private var bands: [Band] {
        var out: [Band] = []
        if state.isCharging, state.hasFreshReading(.charging) {
            let minutes = Double(state.remainingChargingMinutes ?? 60)
            out.append(Band(start: 0, end: fraction(now.addingTimeInterval(minutes * 60)), live: true))
        }
        for entry in entries where entry.schedule.kind == .globalCharging || entry.schedule.kind == .locationCharging {
            guard let start = entry.next, start.timeIntervalSince(now) < Self.span else { continue }
            var end = start.addingTimeInterval(3_600)
            if let hour = entry.schedule.endHour {
                let calendar = Calendar.current
                if let sameDay = calendar.date(bySettingHour: hour, minute: entry.schedule.endMinute ?? 0,
                                               second: 0, of: start) {
                    end = sameDay > start ? sameDay : sameDay.addingTimeInterval(86_400)
                }
            }
            out.append(Band(start: fraction(start), end: fraction(end), live: false))
        }
        return out
    }

    private var marks: [Mark] {
        entries.compactMap { entry in
            guard entry.schedule.kind == .climate || entry.schedule.kind == .departure,
                  let next = entry.next, next.timeIntervalSince(now) < Self.span else { return nil }
            return Mark(at: fraction(next), kind: entry.schedule.kind)
        }
    }

    private var spokenSummary: String {
        entries.compactMap { entry -> String? in
            guard let next = entry.next, next.timeIntervalSince(now) < Self.span else { return nil }
            return "\(entry.schedule.kind.title) \(Format.timeFormatter.string(from: next))"
        }.joined(separator: ", ")
    }

    var body: some View {
        let bands = bands
        let marks = marks
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(HisingenTheme.hairline)
                        .frame(height: 1)
                        .offset(y: 13)
                    ForEach(bands, id: \.self) { band in
                        Rectangle()
                            .fill(HisingenTheme.liveSignal.opacity(band.live ? 1 : 0.45))
                            .frame(width: max(2, (band.end - band.start) * width), height: 8)
                            .offset(x: band.start * width, y: 9.5)
                    }
                    ForEach(marks, id: \.self) { mark in
                        Rectangle()
                            .fill(HisingenTheme.ink)
                            .frame(width: mark.kind == .departure ? 2 : 6, height: mark.kind == .departure ? 22 : 8)
                            .offset(x: min(max(mark.at * width - 1, 0), width - 2),
                                    y: mark.kind == .departure ? 2 : 9.5)
                    }
                    // Now, at the left edge.
                    Rectangle()
                        .fill(HisingenTheme.ink)
                        .frame(width: 1, height: 14)
                        .offset(y: 6)
                }
            }
            .frame(height: 26)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { hours in
                        let date = now.addingTimeInterval(Double(hours) * 3_600)
                        Text(hours == 0 ? L10n.text("Now") : Format.localizedDateFormatter(hourOnly: true).string(from: date))
                            .hisType(.micro)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                let x = CGFloat(hours) / 24 * width
                                return hours == 0 ? -x : (hours == 24 ? d.width - x : d.width / 2 - x)
                            }
                    }
                }
            }
            .frame(height: 14)

            if !bands.isEmpty || !marks.isEmpty {
                HStack(spacing: 14) {
                    if !bands.isEmpty { legend(HisingenTheme.liveSignal.opacity(0.45), L10n.text("Charging Window"), width: 10) }
                    if marks.contains(where: { $0.kind == .climate }) { legend(HisingenTheme.ink, L10n.text("Cabin Climate"), width: 6) }
                    if marks.contains(where: { $0.kind == .departure }) { legend(HisingenTheme.ink, L10n.text("Departure"), width: 2) }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Schedules"))
        .accessibilityValue(spokenSummary)
    }

    private func legend(_ color: Color, _ title: String, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: width, height: 8)
            Text(title)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
    }
}
