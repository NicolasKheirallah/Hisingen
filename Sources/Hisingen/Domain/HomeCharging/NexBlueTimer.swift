import Foundation

enum NexBlueTimerError: LocalizedError, Equatable {
    case unsupported, activeSchedule, noSlot, missingPrices, noWindow, changed, unconfirmed

    var errorDescription: String? {
        switch self {
        case .unsupported: return L10n.text("This timer needs a NexBlue charger in Sweden set to normal scheduling mode.")
        case .activeSchedule: return L10n.text("An active schedule is already set in myNexBlue.")
        case .noSlot: return L10n.text("Both schedule slots are in use. You can manage them in myNexBlue.")
        case .missingPrices: return L10n.text("Spot prices for the whole overnight period are not available yet.")
        case .noWindow: return L10n.text("No timer window fits tonight. Try a shorter duration.")
        case .changed: return L10n.text("The charger or window changed. Preview the timer again.")
        case .unconfirmed: return L10n.text("The timer could not be verified. Check Schedule in myNexBlue before trying again.")
        }
    }
}

struct NexBlueScheduleItem: Codable, Equatable, Sendable {
    let startHour: Int
    let startMinute: Int
    let stopHour: Int
    let stopMinute: Int
    let repeatDays: [Int]
    let enabled: Bool
    let scheduleCurrentLimit: Int?

    init(window: DateInterval, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        startHour = calendar.component(.hour, from: window.start)
        startMinute = calendar.component(.minute, from: window.start)
        stopHour = calendar.component(.hour, from: window.end)
        stopMinute = calendar.component(.minute, from: window.end)
        repeatDays = []
        enabled = true
        scheduleCurrentLimit = nil
    }

    func matches(_ item: Self) -> Bool {
        startHour == item.startHour && startMinute == item.startMinute &&
            stopHour == item.stopHour && stopMinute == item.stopMinute &&
            repeatDays == item.repeatDays && enabled == item.enabled &&
            (item.scheduleCurrentLimit == nil || item.scheduleCurrentLimit == 32)
    }
}

struct NexBlueSchedule: Equatable, Sendable {
    let timeZone: TimeZone
    let items: [NexBlueScheduleItem]

    func checkAvailable() throws {
        guard !items.contains(where: \.enabled) else { throw NexBlueTimerError.activeSchedule }
        guard items.count < 2 else { throw NexBlueTimerError.noSlot }
    }
}

struct NexBlueTimerPreview: Equatable, Sendable {
    let chargerID: String
    let zone: ElspotZone
    let schedule: NexBlueSchedule
    let window: DateInterval

    var item: NexBlueScheduleItem { NexBlueScheduleItem(window: window, timeZone: schedule.timeZone) }

    static func make(chargerID: String, schedule: NexBlueSchedule, zone: ElspotZone, prices: [ElectricityPricePoint],
                     hours: Int, now: Date) throws -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone
        let today = calendar.startOfDay(for: now)
        guard let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: today),
              let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: morning) else { throw NexBlueTimerError.noWindow }
        let earliest = max(now.addingTimeInterval(5 * 60), now < morning ? now : evening)
        let deadline = now < morning ? morning : tomorrow
        let duration = TimeInterval(hours) * 3_600
        guard (1...8).contains(hours), deadline.timeIntervalSince(earliest) >= duration else { throw NexBlueTimerError.noWindow }
        let range = DateInterval(start: earliest, end: deadline)
        switch ChargingPlanner.cheapestWindow(prices: prices, within: range, duration: duration, canSchedule: {
            canRepresent($0, in: schedule.timeZone, after: now)
        }) {
        case .missingPrices: throw NexBlueTimerError.missingPrices
        case .unavailable: throw NexBlueTimerError.noWindow
        case .available(let window): return Self(chargerID: chargerID, zone: zone, schedule: schedule, window: window)
        }
    }

    static func canRepresent(_ window: DateInterval, in timeZone: TimeZone, after now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func matchesNextClockTime(_ date: Date, after reference: Date) -> Bool {
            var parts = calendar.dateComponents([.hour, .minute], from: date)
            parts.second = 0
            let first = calendar.nextDate(after: reference, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first)
            let last = calendar.nextDate(after: reference, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last)
            let day = calendar.startOfDay(for: date).addingTimeInterval(-1)
            let firstOnDay = calendar.nextDate(after: day, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first)
            let lastOnDay = calendar.nextDate(after: day, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last)
            return first == date && last == date && firstOnDay == lastOnDay
        }
        return timeZone.secondsFromGMT(for: window.start) == timeZone.secondsFromGMT(for: window.end)
            && matchesNextClockTime(window.start, after: now)
            && matchesNextClockTime(window.end, after: window.start)
    }
}
