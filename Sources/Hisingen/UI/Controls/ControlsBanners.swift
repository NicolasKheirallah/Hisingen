import AppKit
import SwiftUI

@MainActor
struct ControlsBanners: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let state: VehicleState
    let feedback: RemoteCommandFeedback?
    let features: Set<AppFeature>
    let isBrandVolvo: Bool
    let showRestrictedNotice: Bool
    var showsVehicleOffline = true
    var showsCommandReceipts = false
    /// Runs the authorization step a refused command asked for. The banner is where the refusal is
    /// read, so the fix belongs beside it instead of in a sentence about another screen.
    var onAuthorizeRemoteCommands: (() -> Void)? = nil
    /// Sends the retry or undo a result offered. The caller dispatches it through the normal path, so
    /// the gate and authorization run again.
    var onFollowUp: ((RemoteCommand) -> Void)? = nil

    @State private var dismissedFeedbackID: UUID?
    /// Drives the 45-second expiry. It was a wall-clock comparison evaluated only when the view
    /// happened to re-render, so a banner could sit past its expiry indefinitely on an idle panel.
    @State private var now = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var vehicleOffline: Bool {
        if showsVehicleOffline, case .unavailable = state.identity.availability { return true }
        return false
    }

    /// Only a known lapse raises this. `nil` means the provider exposes no subscription resource
    /// or the read failed, and an unknown must never look like a warning.
    private var subscriptionLapsed: Bool {
        state.identity.hasPremiumSubscription == false
    }

    private var liveFeedback: RemoteCommandFeedback? {
        guard let feedback,
              feedback.targetVIN.map({ $0.caseInsensitiveCompare(state.identity.vin) == .orderedSame }) ?? true,
              feedback.id != dismissedFeedbackID,
              now.timeIntervalSince(feedback.issuedAt) < 45 else {
            return nil
        }
        if showsCommandReceipts, feedback.success, feedback.followUp == nil, feedback.remedy == nil,
           let commandIdentifier = feedback.commandIdentifier,
           state.commandState.receipts.contains(where: {
               $0.commandIdentifier == commandIdentifier
                   && abs($0.issuedAt.timeIntervalSince(feedback.issuedAt)) <= 5
           }) {
            return nil
        }
        return feedback
    }

    var body: some View {
        Group {
            if let feedback = liveFeedback {
                feedbackBanner(feedback)
                    // The expiry needs a clock, not a render, and only while a banner is up:
                    // an always-on timer rewrote state every 5 s with nothing to expire.
                    .onAppear { now = Date() }
                    .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { tick in
                        now = tick
                    }
            }
            if vehicleOffline {
                offlineBanner
            }
            if subscriptionLapsed {
                subscriptionBanner
            }
        }
        // Keyed on each banner's driving identity so an insertion carries the
        // entrance while the removal rides the dismissing transaction.
        .hisAnimation(Motion.entrance, value: liveFeedback?.id)
        .hisAnimation(Motion.entrance, value: vehicleOffline)
        .hisAnimation(Motion.entrance, value: subscriptionLapsed)
    }

    private func feedbackBanner(_ feedback: RemoteCommandFeedback) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .hisType(.title)
                .foregroundStyle(feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .hisAnimation(Motion.stateChange, value: feedback.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .hisType(.label, weight: .semibold)
                    .foregroundStyle(HisingenTheme.ink)
                Text(feedback.message)
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if feedback.remedy == .authorizeRemoteCommands, let onAuthorizeRemoteCommands {
                Button {
                    withAnimation(Motion.resolve(Motion.cardChange)) { dismissedFeedbackID = feedback.id }
                    onAuthorizeRemoteCommands()
                } label: {
                    Text(L10n.text("Authorize…"))
                        .hisType(.caption, weight: .semibold)
                }
                .buttonStyle(.hisProminent)
                .controlSize(.small)
                .fixedSize()
            }
            // Only for the vehicle the banner describes. After the reader switches cars, a retry or
            // undo for the previous one would act on the wrong vehicle.
            if let followUp = feedback.followUp, followUp.targetVIN == state.identity.vin,
               let onFollowUp {
                Button {
                    withAnimation(Motion.resolve(Motion.cardChange)) { dismissedFeedbackID = feedback.id }
                    onFollowUp(followUp.command)
                } label: {
                    Text(followUp.kind == .retry ? L10n.text("Retry") : L10n.text("Undo"))
                        .hisType(.caption, weight: .semibold)
                }
                .buttonStyle(.hisSecondary)
                .controlSize(.small)
                .fixedSize()
            }
            DismissButton {
                withAnimation(Motion.resolve(Motion.cardChange)) { dismissedFeedbackID = feedback.id }
            }
        }
        .padding(10)
        .padding(.leading, 2)
        .hisNotice(feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .task(id: feedback.id) {
            guard feedback.success else { return }
            // An undo is only useful while the reader can still act on the result they just saw.
            let window: Double = feedback.followUp?.kind == .undo ? 30 : 6
            try? await Task.sleep(for: .seconds(window))
            withAnimation(Motion.resolve(Motion.cardChange)) { dismissedFeedbackID = feedback.id }
        }
    }

    /// A lapsed premium subscription is why a command can be refused with no fault anywhere else.
    /// Naming it here saves the reader from working through privacy mode, sleep, and signal first.
    private var subscriptionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "creditcard")
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.semanticWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("No active Volvo subscription"))
                    .hisType(.label, weight: .semibold)
                Text(L10n.text("Remote commands need an active subscription on this car."))
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            Spacer()
        }
        .padding(10)
        .padding(.leading, 2)
        .hisNotice(HisingenTheme.semanticWarning)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.semanticWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Vehicle is offline"))
                    .hisType(.label, weight: .semibold)
                Text(L10n.text("Commands may not be delivered until it reconnects."))
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            Spacer()
        }
        .padding(10)
        .padding(.leading, 2)
        .hisNotice(HisingenTheme.semanticWarning)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

/// Which remote-control groups are switched on, as a footnote under Plan's controls. It explains a
/// missing control, so it speaks only when a group is off, and it sits after the controls rather
/// than above the schedule the reader opened the tab for.
@MainActor
struct RemoteControlsFootnote: View {
    let features: Set<AppFeature>
    let isBrandVolvo: Bool

    private var allEnabled: Bool {
        AppFeature.allCases.filter(\.isRemoteControl).allSatisfy { features.contains($0) }
    }

    var body: some View {
        if !allEnabled {
            let activeNames = AppFeature.allCases
                .filter { $0.isRemoteControl && features.contains($0) }
                .map(\.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(isBrandVolvo ? L10n.text("Volvo Connected Vehicle API") : L10n.text("Polestar Remote Commands"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.ink)
                Text(activeNames.isEmpty
                     ? L10n.text("No remote-control features are enabled.")
                     : L10n.format("Enabled: %@.", activeNames.joined(separator: ", ")))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .overlay(alignment: .top) { PanelRule() }
            .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
struct ControlsReprobeButton: View {
    let onRefresh: () -> Void

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            onRefresh()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(L10n.text("Re-check what this vehicle supports"))
                    .hisType(.caption, weight: .medium)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.hisSecondary)
        .controlSize(.small)
        .help(L10n.text("Refreshes telemetry and re-probes the vehicle's capability set."))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension ControlsCommandGate {
    @ViewBuilder
    func dimReason(_ availability: CommandAvailability) -> some View {
        if let reason = availability.shortReason {
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .hisType(.micro)
                Text(reason)
                    .hisType(.micro)
            }
            .foregroundStyle(HisingenTheme.inkMuted)
        }
    }

    @ViewBuilder
    func sendingOverlay(_ command: RemoteCommand) -> some View {
        // The animation lives on a container that survives the branch flip, so the
        // capsule's insertion and removal both get the acknowledge-then-settle pace
        // even though hosts toggle `isSending` outside any `withAnimation`.
        ZStack {
            if isSending(command) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(L10n.text("Sending…")).hisType(.micro, weight: .medium)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(HisingenTheme.chipFill, in: RoundedRectangle(cornerRadius: 0))
                .transition(Motion.prefersReducedMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .hisAnimation(Motion.interaction, value: isSending(command))
    }
}
