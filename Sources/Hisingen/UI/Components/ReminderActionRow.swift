import SwiftUI

/// A small "Add Reminder" action with its own result feedback, for cards that report
/// a state worth acting on later (service due, tyre warnings, low battery). Each row
/// keeps its own outcome so two actions on one card never overwrite each other's
/// message. The closure owns the writer call; the card owns the long-lived writer.
struct ReminderActionRow: View {
    let title: String
    let create: @MainActor () async -> ReminderWriter.Outcome

    @State private var outcome: ReminderWriter.Outcome?
    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard !inFlight else { return }
                inFlight = true
                Task { @MainActor in
                    outcome = await create()
                    inFlight = false
                }
            } label: {
                Label(L10n.text(title), systemImage: "reminder")
                    .hisType(.caption, weight: .medium)
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)
            .disabled(inFlight)
            .accessibilityLabel(L10n.text(title))
            if let outcome {
                ReminderOutcomeLabel(outcome: outcome)
            }
        }
        .hisAnimation(Motion.stateChange, value: outcome)
    }
}

/// The result line under an Add Reminder action, in the shape of the calendar card's
/// denied banner: icon plus text, plain facts, the fix named when there is one.
private struct ReminderOutcomeLabel: View {
    let outcome: ReminderWriter.Outcome

    var body: some View {
        switch outcome {
        case .created:
            Label(L10n.text("Added to Reminders."), systemImage: "checkmark.circle")
                .hisType(.micro).foregroundStyle(HisingenTheme.semanticGood)
                .hisCaptionLeading()
        case .duplicate:
            Label(L10n.text("Already in Reminders."), systemImage: "checkmark.circle")
                .hisType(.micro).foregroundStyle(.secondary)
                .hisCaptionLeading()
        case .denied:
            Label(L10n.text("Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders."),
                  systemImage: "lock.trianglebadge.exclamationmark")
                .hisType(.micro).foregroundStyle(HisingenTheme.semanticWarning)
                .hisCaptionLeading()
                .fixedSize(horizontal: false, vertical: true)
        case .noDefaultList:
            Label(L10n.text("No default Reminders list is available."), systemImage: "exclamationmark.circle")
                .hisType(.micro).foregroundStyle(HisingenTheme.semanticWarning)
                .hisCaptionLeading()
        case .saveFailed:
            Label(L10n.text("The reminder could not be saved."), systemImage: "exclamationmark.circle")
                .hisType(.micro).foregroundStyle(HisingenTheme.semanticWarning)
                .hisCaptionLeading()
        case .noAccess, .disabled:
            // Only the automated path produces these; a manual action never can.
            EmptyView()
        }
    }
}
