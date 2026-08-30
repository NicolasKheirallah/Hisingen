import EventKit
import SwiftUI

@MainActor
struct CalendarPreconditioningSettingsCard: View {
    let binder: PreferenceBinder

    /// One long-lived store for the whole card (EventKit prefers this over ad-hoc instances).
    @State private var eventStore = EKEventStore()
    @State private var calendars: [EKCalendar] = []
    @State private var permissionDenied = false
    @State private var requestingAccess = false
    @State private var nextPreview: String?

    private var preferences: PreferencesStore { binder.preferences }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.calendarPreconditioningEnabled },
            set: { enabled in
                if enabled { Task { await enable() } }
                else {
                    preferences.calendarPreconditioningEnabled = false
                    binder.notify(.automation)
                    binder.bump()
                }
            }
        )
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "calendar.badge.clock",
                               title: L10n.text("Calendar Preconditioning"), color: .purple)
                    Spacer()
                    if requestingAccess { ProgressView().controlSize(.small) }
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel(L10n.text("Calendar preconditioning"))
                }
                Text(L10n.text("Start climate before timed events in calendars you choose. The command targets the currently active vehicle."))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.requireBiometricsForRemoteControls {
                    Label(L10n.text("Because you require device-owner authentication for remote controls, calendar-triggered climate starts run without that prompt — nobody is present to answer it when they fire."),
                          systemImage: "info.circle")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if permissionDenied {
                    Label(L10n.text("Calendar access is denied. Allow Hisingen in System Settings → Privacy & Security → Calendars."),
                          systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 9.5)).foregroundStyle(.orange)
                }

                if CalendarPreconditioningController.hasCalendarAccess {
                    HStack {
                        Text(L10n.text("Lead time")).font(.system(size: 10, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { preferences.calendarPreconditioningLeadTimeMinutes },
                            set: { value in
                                preferences.calendarPreconditioningLeadTimeMinutes = value
                                binder.notify(.automation); binder.bump()
                                refreshPreview()
                            }
                        )) {
                            ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { value in
                                Text(L10n.format("%d minutes", value)).tag(value)
                            }
                        }
                        .labelsHidden().controlSize(.small).frame(width: 120)
                    }

                    if preferences.calendarPreconditioningEnabled, let nextPreview {
                        Label(nextPreview, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 9)).foregroundStyle(HisingenTheme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().opacity(0.35)
                    Text(L10n.text("Selected calendars"))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    if calendars.isEmpty {
                        Text(L10n.text("No event calendars are available."))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    } else {
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: calendarBinding(calendar.calendarIdentifier)) {
                                HStack(spacing: 7) {
                                    Circle().fill(Color(nsColor: calendar.color))
                                        .frame(width: 8, height: 8)
                                    Text(calendar.title).font(.system(size: 10))
                                    Spacer()
                                    Text(calendar.source.title)
                                        .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
        .task { loadCalendars(); refreshPreview() }
    }

    private func calendarBinding(_ identifier: String) -> Binding<Bool> {
        Binding(
            get: { preferences.calendarPreconditioningCalendarIDs.contains(identifier) },
            set: { selected in
                var ids = preferences.calendarPreconditioningCalendarIDs
                if selected { ids.insert(identifier) } else { ids.remove(identifier) }
                preferences.calendarPreconditioningCalendarIDs = ids
                binder.notify(.automation)
                binder.bump()
                refreshPreview()
            }
        )
    }

    private func enable() async {
        requestingAccess = true
        defer { requestingAccess = false }
        let granted: Bool
        do { granted = try await eventStore.requestFullAccessToEvents() }
        catch { granted = false }
        permissionDenied = !granted
        guard granted else {
            preferences.calendarPreconditioningEnabled = false
            binder.bump()
            return
        }
        calendars = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
        if preferences.calendarPreconditioningCalendarIDs.isEmpty,
           let defaultCalendar = eventStore.defaultCalendarForNewEvents {
            preferences.calendarPreconditioningCalendarIDs = [defaultCalendar.calendarIdentifier]
        }
        preferences.calendarPreconditioningEnabled = true
        binder.notify(.automation)
        binder.bump()
        refreshPreview()
    }

    private func loadCalendars() {
        permissionDenied = EKEventStore.authorizationStatus(for: .event) == .denied
        guard CalendarPreconditioningController.hasCalendarAccess else { return }
        calendars = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
    }

    private func refreshPreview() {
        guard preferences.calendarPreconditioningEnabled,
              let next = CalendarPreconditioningController.nextTrigger(
                eventStore: eventStore, preferences: preferences) else {
            nextPreview = nil
            return
        }
        let eventTime = next.eventStart.formatted(date: .omitted, time: .shortened)
        let climateTime = next.fireAt.formatted(date: .omitted, time: .shortened)
        nextPreview = L10n.format("Next: %@ at %@ — climate starts %@", next.title, eventTime, climateTime)
    }
}
