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

    private var vehicleOffline: Bool {
        if case .unavailable = state.identity.availability { return true }
        return false
    }

    private var liveFeedback: RemoteCommandFeedback? {
        guard let feedback,
              feedback.id != dismissedFeedbackID,
              Date().timeIntervalSince(feedback.issuedAt) < 45 else {
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
    }

    private func feedbackBanner(_ feedback: RemoteCommandFeedback) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(feedback.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation { dismissedFeedbackID = feedback.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Dismiss"))
        }
        .padding(10)
        .background(
            (feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    (feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.28),
                    lineWidth: 0.5
                )
        )
        .accessibilityElement(children: .combine)
        .task(id: feedback.id) {
            guard feedback.success else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { dismissedFeedbackID = feedback.id }
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14))
                .foregroundStyle(HisingenTheme.semanticWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Vehicle is offline"))
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.text("Commands may not be delivered until it reconnects."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.semanticWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var restrictedNoticeBanner: some View {
        let activeNames = AppFeature.allCases
            .filter { $0.isRemoteControl && features.contains($0) }
            .map(\.title)

        return HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(HisingenTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(isBrandVolvo ? L10n.text("Volvo Connected Vehicle API") : L10n.text("Polestar Remote Commands"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(activeNames.isEmpty
                     ? L10n.text("No remote-control features are enabled.")
                     : L10n.format("Enabled: %@.", activeNames.joined(separator: ", ")))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(HisingenTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
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
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.text("Refreshes telemetry and re-probes the vehicle's capability set."))
    }
}

extension ControlsCommandGate {
    @ViewBuilder
    func dimReason(_ availability: CommandAvailability) -> some View {
        if let reason = availability.shortReason {
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text(reason)
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func sendingOverlay(_ command: RemoteCommand) -> some View {
        if isSending(command) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(L10n.text("Sending…")).font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
