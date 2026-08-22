import AppKit
import SwiftUI

/// Tiny always-on-top panel shown while the vehicle is charging. Non-activating, so it never
/// steals focus from the user's work; position is autosaved. Exists purely to answer
/// "how's the charge going" at a glance — it performs no actions and holds no state of its own.
@MainActor
final class ChargingMiniPanelController {
    private var panel: NSPanel?
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    private var isEnabled: Bool { preferences.floatingChargingPanelEnabled }

    func update(state: VehicleState?) {
        guard let state, isEnabled, state.isCharging else {
            close()
            return
        }
        if panel == nil { makePanel() }
        guard let panel else { return }

        let host = NSHostingView(rootView: ChargingMiniPanelView(
            batteryPercentage: state.batteryPercentage,
            powerWatts: state.chargingPowerWatts,
            minutesToTarget: state.batteryDiagnostics?.timeToTargetMinutes
                ?? state.estimatedChargingTimeToFullMinutes,
            targetPercent: state.chargeTargetPercentage
        ))
        panel.contentView = host
        // Only order front when hidden so dragging the panel isn't disrupted by updates.
        if !panel.isVisible {
            panel.setFrameOrigin(topRightPosition(for: panel.frame.size))
            panel.orderFrontRegardless()
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 190, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("ChargingMiniPanel")
        self.panel = panel
    }

    /// Default anchor: top-right with a comfortable margin from the menu bar corner.
    private func topRightPosition(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 40, y: 40) }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - size.width - 12,
                       y: visible.maxY - size.height - 8)
    }
}

private struct ChargingMiniPanelView: View {
    let batteryPercentage: Double?
    let powerWatts: Int?
    let minutesToTarget: Int?
    let targetPercent: Int?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text(L10n.text("Charging"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let target = targetPercent, target < 100,
                   let battery = batteryPercentage {
                    Text("\(String(format: "%.0f", battery))→\(target)%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else if let battery = batteryPercentage {
                    Text(String(format: "%.0f%%", battery))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                if let watts = powerWatts, watts > 0 {
                    Label(Format.kilowatts(watts: watts), systemImage: "bolt.fill")
                }
                if let minutes = minutesToTarget, minutes > 0 {
                    Label(Format.shortDuration(minutes: minutes), systemImage: "timer")
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 190)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.08),
                                      lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Charging status"))
    }
}
