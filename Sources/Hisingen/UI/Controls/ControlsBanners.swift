import AppKit
import SwiftUI

@MainActor
struct ControlsBanners: View {
    let state: VehicleState
    let feedback: RemoteCommandFeedback?
    let features: Set<AppFeature>
    let isBrandVolvo: Bool
    let showRestrictedNotice: Bool

    @State private var dismissedFeedbackID: UUID?
    /// Drives the 45-second expiry. It was a wall-clock comparison evaluated only when the view
    /// happened to re-render, so a banner could sit past its expiry indefinitely on an idle panel.
    @State private var now = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var vehicleOffline: Bool {
        if case .unavailable = state.identity.availability { return true }
        return false
    }

    private var liveFeedback: RemoteCommandFeedback? {
        guard let feedback,
              feedback.id != dismissedFeedbackID,
              now.timeIntervalSince(feedback.issuedAt) < 45 else {
            return nil
        }
        return feedback
    }

    var body: some View {
        Group {
            if let feedback = liveFeedback {
                feedbackBanner(feedback)
            }
            if vehicleOffline {
                offlineBanner
            }
            if showRestrictedNotice {
                restrictedNoticeBanner
            }
        }
        // Keyed on each banner's driving identity so an insertion carries the
        // entrance while the removal rides the dismissing transaction.
        .hisAnimation(Motion.entrance, value: liveFeedback?.id)
        .hisAnimation(Motion.entrance, value: vehicleOffline)
        .hisAnimation(Motion.entrance, value: showRestrictedNotice)
        // The expiry needs a clock, not a render.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { tick in
            now = tick
        }
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
                    .foregroundStyle(.primary)
                Text(feedback.message)
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(Motion.resolve(Motion.cardChange)) { dismissedFeedbackID = feedback.id }
            } label: {
                Image(systemName: "xmark")
                    .hisType(.caption, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(L10n.text("Dismiss"))
        }
        .padding(10)
        .background(
            (feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.10),
            in: RoundedRectangle(cornerRadius: HisingenTheme.bannerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HisingenTheme.bannerRadius, style: .continuous)
                .stroke(
                    (feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.28),
                    lineWidth: 0.5
                )
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .task(id: feedback.id) {
            guard feedback.success else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(Motion.resolve(Motion.cardChange)) { dismissedFeedbackID = feedback.id }
        }
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
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.semanticWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: HisingenTheme.bannerRadius, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    private var restrictedNoticeBanner: some View {
        let activeNames = AppFeature.allCases
            .filter { $0.isRemoteControl && features.contains($0) }
            .map(\.title)

        return HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .hisType(.title)
                .foregroundStyle(HisingenTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(isBrandVolvo ? L10n.text("Volvo Connected Vehicle API") : L10n.text("Polestar Remote Commands"))
                    .hisType(.label, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(activeNames.isEmpty
                     ? L10n.text("No remote-control features are enabled.")
                     : L10n.format("Enabled: %@.", activeNames.joined(separator: ", ")))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: HisingenTheme.bannerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HisingenTheme.bannerRadius, style: .continuous)
                .stroke(HisingenTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
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
        .buttonStyle(.bordered)
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
            .foregroundStyle(.secondary)
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
                .background(HisingenTheme.chipFill, in: Capsule())
                .transition(Motion.prefersReducedMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .hisAnimation(Motion.interaction, value: isSending(command))
    }
}
