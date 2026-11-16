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
        // Match the SwiftUI width so the frame never clips the content.
        let scaledWidth: CGFloat = 200
        let fittedHeight = max(panel.contentView?.fittingSize.height ?? 0, 92)
        // Appearing and disappearing are the same transition in both directions: they used
        // different curves at different durations, so dismissal did not retrace appearance, and
        // neither consulted Reduce Motion in a file that checks it for the glyph twenty lines away.
        let reduceMotion = Motion.prefersReducedMotion
        if !panel.isVisible {
            panel.alphaValue = 0
            let size = NSSize(width: scaledWidth, height: fittedHeight)
            if panel.frameAutosaveName.isEmpty || !panel.setFrameUsingName("ChargingMiniPanel") {
                panel.setFrame(NSRect(origin: topRightPosition(for: size), size: size), display: true)
            } else if panel.frame.width != scaledWidth || panel.frame.height != fittedHeight {
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
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("Charging"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Spacer()
                // The panel floats above every window, on every Space, over full-screen apps, and
                // it holds no controls of its own: the only way to dismiss it was to know the
                // switch lived in Settings. A way out belongs where the thing appears.
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .hisSymbolSize(10)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .help(L10n.text("Hide this panel"))
                    .accessibilityLabel(L10n.text("Hide this panel"))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let battery = batteryPercentage {
                    Text(String(format: "%.0f", locale: L10n.displayLocale, battery))
                        .hisType(size: 30, relativeTo: .title)
                        .monospacedDigit()
                        .hisTelemetryValue(battery, reduceMotion: reduceMotion)
                    Text("%")
                        .hisType(.subhead)
                        .foregroundStyle(HisingenTheme.inkMuted)
                    if let target = targetPercent, target < 100 {
                        Text(L10n.format("Target %d%%", target))
                            .hisType(.label)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .padding(.leading, 6)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(HisingenTheme.ink)
            .hisAnimation(Motion.telemetry, value: targetPercent)
            HStack(spacing: 10) {
                if let watts = powerWatts, watts > 0 {
                    Text(Format.kilowatts(watts: watts))
                        .hisTelemetryValue(watts, reduceMotion: reduceMotion)
                }
                if let minutes = minutesToTarget, minutes > 0 {
                    Text(Format.shortDuration(minutes: minutes))
                        .hisTelemetryValue(minutes, reduceMotion: reduceMotion)
                }
                Spacer()
            }
            .hisType(.caption)
            .monospacedDigit()
            .foregroundStyle(HisingenTheme.inkMuted)
            EnergyLine(level: batteryPercentage, target: nil, isCharging: true)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(width: 200)
        // Flat and square like the main panel: the canvas, a hairline edge, no material. The
        // NSPanel supplies the window shadow.
        .background(HisingenTheme.canvas)
        .overlay(Rectangle().strokeBorder(contrast == .increased
                                          ? HisingenTheme.cardBoundaryIncreased : HisingenTheme.hairline,
                                          lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Charging status"))
    }
}
