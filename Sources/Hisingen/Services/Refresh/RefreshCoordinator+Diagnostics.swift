import Foundation

extension RefreshCoordinator {
    func publishDiagnostics() {
        let diagnosticRecord = confirmations.diagnosticRecord
        let snapshot = DiagnosticsSnapshot(
            lastSuccess: lastFullRefreshAt,
            lastError: lastError?.localizedDescription,
            latency: lastLatency,
            nextRefresh: nextRefresh,
            sessionValid: sessionReady,
            networkAvailable: networkAvailable,
            refreshInProgress: task != nil,
            unavailableFeatures: latest?.freshness.unavailableFeatures ?? [],
            servingCachedSnapshot: latest?.freshness.isCached ?? false,
            liveStreamConnected: streamEngine?.isConnected ?? false,
            liveStreamRetryAt: streamEngine?.retryAt,
            liveStreamNeedsAuthorization: streamNeedsAuthorization,
            lastLiveFrameAt: streamEngine?.metrics.lastFrameAt,
            liveStreamMetrics: streamEngine?.metrics ?? LiveStreamMetrics(),
            refreshAttempts: refreshAttempts,
            refreshSuccesses: refreshSuccesses,
            refreshFailures: refreshFailures,
            commandConfirmationIdentifier: diagnosticRecord?.receipt.commandIdentifier,
            commandConfirmationStatus: diagnosticRecord?.receipt.status,
            commandConfirmationDeadline: diagnosticRecord?.confirmationDeadline,
            commandConfirmationFeatures: diagnosticRecord?.receipt.confirmationFeatures?.enabled
                .sorted { $0.rawValue < $1.rawValue } ?? [],
            commandConfirmationSuspended: confirmations.isSuspended,
            commandReceiptVisible: !confirmations.visibleReceipts.isEmpty,
            commandReceiptCount: confirmations.visibleReceipts.count,
            awaitingCommandReceiptCount: confirmations.awaitingCount,
            vehicleSwitchPending: requestedSelectionVIN != nil
        )
        // The diagnostics log exporter is fed here, where the snapshot is built, rather than
        // by every event handler, so the store can never drift from what was published.
        diagnosticsSequence &+= 1
        let sequence = diagnosticsSequence
        Task { await LatestDiagnosticsStore.shared.update(snapshot, sequence: sequence) }
        onEvent?(.diagnostics(snapshot))
    }
}
