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
    @State private var previewTask: Task<Void, Never>?

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
                    if requestingAccess {
                        ProgressView().controlSize(.small)
                            .transition(.opacity)
                    }
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel(L10n.text("Calendar preconditioning"))
                }
                Text(L10n.text("Start climate before timed events in calendars you choose. The command targets the currently active vehicle."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.requireBiometricsForRemoteControls {
                    Label(L10n.text("Because you require device-owner authentication for remote controls, calendar-triggered climate starts run without that prompt – nobody is present to answer it when they fire."),
                          systemImage: "info.circle")
                        .hisType(.micro).foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }

                if permissionDenied {
                    Label(L10n.text("Calendar access is denied. Allow Hisingen in System Settings → Privacy & Security → Calendars."),
                          systemImage: "lock.trianglebadge.exclamationmark")
                        .hisType(.micro).foregroundStyle(.orange)
                        .transition(.opacity)
                }

                if CalendarPreconditioningController.hasCalendarAccess {
                    Group {
                        HStack {
                            Text(L10n.text("Lead time")).hisType(.caption, weight: .medium)
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
                                .hisType(.micro).foregroundStyle(HisingenTheme.accent)
                                .hisCaptionLeading()
                                .hisCaptionLeading()
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }

                        Divider().opacity(HisingenTheme.dividerOpacity)
                        Text(L10n.text("Selected calendars"))
                            .hisType(.caption, weight: .semibold).foregroundStyle(.secondary)
                        if calendars.isEmpty {
                            Text(L10n.text("No event calendars are available."))
                                .hisType(.micro).foregroundStyle(.tertiary)
                        } else {
                            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                                Toggle(isOn: calendarBinding(calendar.calendarIdentifier)) {
                                    HStack(spacing: 7) {
                                        Circle().fill(Color(nsColor: calendar.color))
                                            .frame(width: 8, height: 8)
                                        Text(calendar.title).hisType(.caption)
                                        Spacer()
                                        Text(calendar.source.title)
                                            .hisType(.micro).foregroundStyle(.tertiary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            // State writers here run from Task continuations and EventKit callbacks
            // outside any transaction; these bindings power their reveals.
            .hisAnimation(Motion.stateChange, value: requestingAccess)
            .hisAnimation(Motion.stateChange, value: permissionDenied)
            .hisAnimation(Motion.stateChange, value: nextPreview)
            .hisAnimation(Motion.cardChange, value: preferences.calendarPreconditioningEnabled)
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
        withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
            permissionDenied = !granted
        }
        guard granted else {
            preferences.calendarPreconditioningEnabled = false
            binder.bump()
            return
        }
        // The section's insert is driven by bump(); keeping it in the transaction
        // (notify stays out – the app-level refresh must not inherit this motion)
        // is what makes the calendar UI ease in after the grant.
        withAnimation(Motion.resolve(Motion.cardChange)) {
            calendars = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
            if preferences.calendarPreconditioningCalendarIDs.isEmpty,
               let defaultCalendar = eventStore.defaultCalendarForNewEvents {
                preferences.calendarPreconditioningCalendarIDs = [defaultCalendar.calendarIdentifier]
            }
            preferences.calendarPreconditioningEnabled = true
            binder.bump()
        }
        binder.notify(.automation)
        refreshPreview()
    }

    private func loadCalendars() {
        permissionDenied = EKEventStore.authorizationStatus(for: .event) == .denied
        guard CalendarPreconditioningController.hasCalendarAccess else { return }
        calendars = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// The blocking EventKit fetch must not run on the main thread. `nextTrigger` cannot
    /// simply be detached (the controller is MainActor-isolated, so the call would hop
    /// straight back to main), so the Sendable inputs are snapshotted here and the fetch is
    /// mirrored off-main. EKEventStore is documented thread-safe for reads, hence the
    /// `nonisolated(unsafe)` hand-off. Cancelling the previous task debounces the
    /// per-toggle refreshes.
    private func refreshPreview() {
        previewTask?.cancel()
        guard preferences.calendarPreconditioningEnabled else {
            nextPreview = nil
            return
        }
        let hasAccess = CalendarPreconditioningController.hasCalendarAccess
        let calendarIDs = preferences.calendarPreconditioningCalendarIDs
        let lead = TimeInterval(preferences.calendarPreconditioningLeadTimeMinutes * 60)
        let fired = Set(preferences.calendarPreconditioningFiredOccurrences.keys)
        let fallbackTitle = L10n.text("Calendar event")
        nonisolated(unsafe) let store = eventStore
        previewTask = Task {
            let next = await Task.detached(priority: .userInitiated) { () -> (String, Date, Date)? in
                guard hasAccess, !calendarIDs.isEmpty else { return nil }
                let now = Date()
                let calendars = store.calendars(for: .event).filter {
                    calendarIDs.contains($0.calendarIdentifier)
                }
                guard !calendars.isEmpty else { return nil }
                // Matches CalendarPreconditioningController's private 72 h lookahead window.
                let lookahead = TimeInterval(3 * 24 * 3_600)
                let predicate = store.predicateForEvents(
                    withStart: now, end: now.addingTimeInterval(lookahead), calendars: calendars)
                return store.events(matching: predicate)
                    .filter { !$0.isAllDay && $0.startDate > now }
                    .compactMap { event -> (String, Date, Date)? in
                        let key = "\(event.calendarItemIdentifier)|\(Int(event.startDate.timeIntervalSince1970))"
                        guard !fired.contains(key) else { return nil }
                        let fireAt = max(event.startDate.addingTimeInterval(-lead), now)
                        return (event.title ?? fallbackTitle, event.startDate, fireAt)
                    }
                    .min { $0.1 < $1.1 }
            }.value
            guard !Task.isCancelled else { return }
            nextPreview = next.map { title, eventStart, fireAt in
                L10n.format("Next: %@ at %@ – climate starts %@",
                            title,
                            eventStart.formatted(date: .omitted, time: .shortened),
                            fireAt.formatted(date: .omitted, time: .shortened))
            }
        }
    }
}
