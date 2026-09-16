import AppKit
import SwiftUI

/// Tiny always-on-top panel shown while the vehicle is charging. Non-activating, so it never
/// steals focus from the user's work; position is autosaved. Exists purely to answer
/// "how's the charge going" at a glance – it performs no actions and holds no state of its own.
@MainActor
final class ChargingMiniPanelController {
    private var panel: NSPanel?
    /// Kept alive across telemetry updates so SwiftUI diffs – and therefore
    /// cross-fades – new readings into place instead of the whole view being
    /// torn down and rebuilt on every refresh.
    private var host: NSHostingView<ChargingMiniPanelView>?
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

        let content = ChargingMiniPanelView(
            batteryPercentage: state.energy.batteryPercentage,
            powerWatts: state.energy.powerWatts,
            minutesToTarget: state.energy.diagnostics?.timeToTargetMinutes
                ?? state.energy.estimatedTimeToFullMinutes,
            targetPercent: state.energy.targetPercentage,
            onClose: { [weak self] in self?.hidePanel() }
        )
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            panel.contentView = host
            self.host = host
        }
        // Match the SwiftUI width so the frame never clips the density-scaled content.
        let scaledWidth = 190 * HisingenTheme.contentScale
        // Appearing and disappearing are the same transition in both directions: they used
        // different curves at different durations, so dismissal did not retrace appearance, and
        // neither consulted Reduce Motion in a file that checks it for the glyph twenty lines away.
        let reduceMotion = Motion.prefersReducedMotion
        if !panel.isVisible {
            panel.alphaValue = 0
            let size = NSSize(width: scaledWidth, height: panel.frame.height)
            if panel.frameAutosaveName.isEmpty || !panel.setFrameUsingName("ChargingMiniPanel") {
                panel.setFrame(NSRect(origin: topRightPosition(for: size), size: size), display: true)
            } else if panel.frame.width != scaledWidth {
                panel.setContentSize(size)
            }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? Motion.micro : Motion.standard
                context.timingFunction = reduceMotion
                    ? CAMediaTimingFunction(name: .linear)
                    : Motion.entranceTimingFunction
                panel.animator().alphaValue = 1
            }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        let reduceMotion = Motion.prefersReducedMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? Motion.micro : Motion.standard
            // The same curve the appearance uses, so dismissal retraces it rather than
            // ease-in-easing-out over a different duration.
            context.timingFunction = reduceMotion
                ? CAMediaTimingFunction(name: .linear)
                : Motion.entranceTimingFunction
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishClosingPanel()
            }
        })
    }

    /// Turns the floating panel off from the panel itself, which also flips the preference so it
    /// does not reappear on the next charge.
    private func hidePanel() {
        preferences.floatingChargingPanelEnabled = false
        close()
    }

    private func finishClosingPanel() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        // Release the SwiftUI tree with the panel.
        //
        // `host` is retained across telemetry updates on purpose, so SwiftUI diffs readings
        // instead of rebuilding the view. But the charging breath is a `repeatForever` animation,
        // and ordering the panel out left it running against an off-screen window: a charge that
        // ended could leave a perpetual animation alive indefinitely. A closed panel has nothing
        // to show, and `update` rebuilds the host on the next charge.
        host?.removeFromSuperview()
        host = nil
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
    /// Dismisses the panel from the panel. Nil when the host has no way to turn it off.
    var onClose: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.car.fill")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.semanticGood)
                Text(L10n.text("Charging"))
                    .hisType(.label, weight: .semibold)
                Spacer()
                if let target = targetPercent, target < 100,
                   let battery = batteryPercentage {
                    Text("\(String(format: "%.0f", battery))→\(target)%")
                        .hisType(.label, weight: .bold, design: .rounded)
                        .monospacedDigit()
                        .hisTelemetryValue(battery, reduceMotion: reduceMotion)
                        .transition(.opacity)
                } else if let battery = batteryPercentage {
                    Text(String(format: "%.0f%%", battery))
                        .hisType(.heading, weight: .bold, design: .rounded)
                        .monospacedDigit()
                        .hisTelemetryValue(battery, reduceMotion: reduceMotion)
                        .transition(.opacity)
                }
                // The panel floats above every window, on every Space, over full-screen apps, and
                // it holds no controls of its own: the only way to dismiss it was to know the
                // switch lived in Settings. A way out belongs where the thing appears.
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .hisType(.nano, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Hide this panel"))
                    .accessibilityLabel(L10n.text("Hide this panel"))
                }
            }
            .hisAnimation(Motion.telemetry, value: targetPercent)
            HStack(spacing: 10) {
                if let watts = powerWatts, watts > 0 {
                    Label(Format.kilowatts(watts: watts), systemImage: "bolt.fill")
                        .hisTelemetryValue(watts, reduceMotion: reduceMotion)
                }
                if let minutes = minutesToTarget, minutes > 0 {
                    Label(Format.shortDuration(minutes: minutes), systemImage: "timer")
                        .hisTelemetryValue(minutes, reduceMotion: reduceMotion)
                }
                Spacer()
            }
            .hisType(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        // Honors the dropdown's Content Density zoom so the floating panel scales
        // consistently with the main panel's text size preference.
        .frame(width: 190 * HisingenTheme.contentScale)
        .background(
            ZStack {
                HisingenTheme.cardSurface(cornerRadius: HisingenTheme.cornerRadius)
                HisingenTheme.cardRim(
                    cornerRadius: HisingenTheme.cornerRadius,
                    prefersOpaque: reduceTransparency || contrast == .increased
                )
                HisingenTheme.cardBoundary(increasedContrast: contrast == .increased)
            }
        )
        .shadow(
            color: HisingenTheme.shadow(for: .floating).color,
            radius: HisingenTheme.shadow(for: .floating).radius,
            y: HisingenTheme.shadow(for: .floating).y
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Charging status"))
    }
}
