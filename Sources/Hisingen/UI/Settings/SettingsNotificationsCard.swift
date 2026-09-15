import AppKit
import SwiftUI

/// The Notifications section of Settings – the master switch plus every per-event alert
/// toggle and its threshold picker. Extracted from `SettingsView`; binds through
/// `PreferenceBinder` so it needs no local `@State`.
@MainActor
struct SettingsNotificationsCard: View {
    let notificationPermission: NotificationPermission
    let state: VehicleState?
    let binder: PreferenceBinder

    private var prefs: PreferencesStore { binder.preferences }
    private var settingsVehicleVIN: String { state?.identity.vin ?? prefs.vin }

    /// Toggle-dependent rows slide down under their switch; opacity keeps the
    /// insertion from reading as a pop.
    private static let dependentRowTransition: AnyTransition =
        .opacity.combined(with: .move(edge: .top))

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bell.badge", title: L10n.text("Notifications"), color: .orange)

                if notificationPermission == .denied {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .hisType(.body)
                            .foregroundStyle(HisingenTheme.semanticWarning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Notifications Blocked in System Settings"))
                                .hisType(.label, weight: .semibold)
                            Text(L10n.text("These toggles won't alert you until notifications are allowed for Hisingen."))
                                .hisType(.micro)
                                .hisCaptionLeading()
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(L10n.text("Open Settings"))
                                .hisType(.caption, weight: .medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(8)
                    .background(HisingenTheme.semanticWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: 4) {
                    // Master switch – the `.notifications` feature flag lives in
                    // `FeatureSelection`, not a plain bool, so it needs its own binding.
                    // The label promised a "master switch for every local alert below" while the
                    // rows under it stayed enabled and at full strength, so it governed nothing the
                    // reader could see. The list below is now disabled and dimmed by it.
                    notificationRow(
                        symbol: "bell.badge.fill",
                        title: "Notifications",
                        detail: "Master switch for every local alert below",
                        isOn: Binding(
                            get: { prefs.features.contains(.notifications) },
                            set: { enabled in
                                var updated = prefs.features
                                updated.set(.notifications, enabled: enabled)
                                prefs.features = updated
                                binder.bump()
                                binder.notify(.features)
                            }
                        )
                    )

                    Group {
                    notificationRow(
                        symbol: "bolt.badge.clock.fill",
                        title: "Charging Started",
                        detail: "Alert when vehicle starts charging",
                        \.notifyChargingStarted
                    )
                    notificationRow(
                        symbol: "battery.100.bolt",
                        title: "Charging Complete",
                        detail: "Alert when target state of charge is reached",
                        \.notifyChargingComplete
                    )
                    notificationRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Charging Interrupted",
                        detail: "Alert if charging stops unexpectedly",
                        \.notifyChargingProblem
                    )
                    notificationRow(
                        symbol: "battery.25",
                        title: "Low Battery Warning",
                        detail: "Alert when battery falls below threshold",
                        \.notifyLowBattery
                    )

                    notificationRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Software Updates",
                        detail: "Alert when vehicle software becomes available or finishes installing",
                        \.notifySoftwareUpdates
                    )

                    notificationRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Vehicle Warnings & Alarm",
                        detail: "Alert for new service, tyre, light, 12 V, fluid, or alarm warnings",
                        \.notifyVehicleWarnings
                    )

                    notificationRow(
                        symbol: "door.left.hand.open",
                        title: "Open Door or Window",
                        detail: L10n.format("Alert after an opening has been left open for %d minutes", prefs.openingsAlertDelayMinutes),
                        \.notifyOpeningsLeftOpen
                    )
                    if prefs.notifyOpeningsLeftOpen {
                        notificationThresholdRow(
                            title: L10n.text("Open-alert delay"),
                            \.openingsAlertDelayMinutes,
                            values: [5, 10, 15, 30, 60],
                            label: { L10n.format("%d min", $0) }
                        )
                        .transition(Self.dependentRowTransition)
                    }

                    notificationRow(
                        symbol: "wrench.and.screwdriver.fill",
                        title: "Service Due Soon",
                        detail: "Alert at 30 days, 1,000 km, or a provider service warning",
                        \.notifyServiceDue
                    )

                    notificationRow(
                        symbol: "clock.badge.exclamationmark",
                        title: "Stale Vehicle Data",
                        detail: "Alert when provider telemetry remains older than its freshness limit",
                        \.notifyStaleTelemetry
                    )

                    notificationRow(
                        symbol: "bolt.trianglebadge.exclamationmark.fill",
                        title: "Unusually Slow Charging",
                        detail: "Alert below 2 kW for 15 minutes while actively charging",
                        \.notifySlowCharging
                    )

                    notificationRow(
                        symbol: "powerplug.fill",
                        title: "Plug-In Reminder",
                        detail: L10n.format("Alert once at %d%% or below while unplugged and not charging", prefs.plugInReminderThreshold),
                        \.notifyPlugInReminder
                    )
                    if prefs.notifyPlugInReminder {
                        notificationThresholdRow(
                            title: L10n.text("Plug-in battery threshold"),
                            \.plugInReminderThreshold,
                            values: Array(stride(from: 10, through: 80, by: 10)),
                            label: { "\($0)%" }
                        )
                        .transition(Self.dependentRowTransition)
                    }

                    notificationRow(
                        symbol: "cable.connector",
                        title: "Cable Connect / Disconnect",
                        detail: "Confirm when a charge cable is plugged in or unplugged",
                        \.notifyChargerConnection
                    )

                    notificationRow(
                        symbol: "windshield.front.and.heat.waves",
                        title: "Climate Start / Stop",
                        detail: "Alert when cabin preconditioning starts or stops",
                        \.notifyClimateChanges
                    )

                    if prefs.notifyLowBattery {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.below.rectangle")
                                .hisType(.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(L10n.text("Alert Threshold"))
                                .hisType(.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: binder(\.lowBatteryThreshold, .notifications)) {
                                ForEach(stride(from: 5, through: 50, by: 5).map { $0 }, id: \.self) { v in
                                    Text("\(v)%").tag(v)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 80)
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 2)
                        .transition(Self.dependentRowTransition)
                    }

                    Divider().opacity(HisingenTheme.dividerOpacity)
                        .padding(.vertical, 2)

                    notificationRow(
                        symbol: "cloud.rain.fill",
                        title: "Rain Alert (Windows Open)",
                        detail: "Alert if rain starts while windows or sunroof are open",
                        \.notifyRainWithWindowsOpen
                    )

                    notificationRow(
                        symbol: "lock.shield.fill",
                        title: "Evening Unlocked Reminder",
                        detail: L10n.format("Alert if parked and unlocked after %02d:00", prefs.eveningUnlockedStartHour),
                        \.notifyEveningUnlocked
                    )
                    if prefs.notifyEveningUnlocked {
                        notificationThresholdRow(
                            title: L10n.text("Evening reminder starts"),
                            \.eveningUnlockedStartHour,
                            values: Array(18...23),
                            label: { String(format: "%02d:00", $0) }
                        )
                        .transition(Self.dependentRowTransition)
                    }

                    Divider().opacity(HisingenTheme.dividerOpacity)
                        .padding(.vertical, 2)

                    notificationRow(
                        symbol: "speaker.wave.2.fill",
                        title: "Notification Sounds",
                        detail: "Play a sound on urgent alerts – alarms, warnings and charging problems",
                        \.notifySounds
                    )

                    notificationRow(
                        symbol: "moon.zzz.fill",
                        title: "Quiet Hours",
                        detail: "Hold non-urgent alerts until the morning; security alerts always come through",
                        \.quietHoursEnabled
                    )
                    if prefs.quietHoursEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .hisType(.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(L10n.text("Window"))
                                .hisType(.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: binder(\.quietHoursStartHour, .notifications)) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 76)
                            Text(L10n.text("to"))
                                .hisType(.label)
                                .foregroundStyle(.secondary)
                            Picker("", selection: binder(\.quietHoursEndHour, .notifications)) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 76)
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 2)
                        .transition(Self.dependentRowTransition)
                    }

                    notificationRow(
                        symbol: "app.badge.fill",
                        title: "Warning Badge",
                        detail: "Show a dock badge while any vehicle reports warnings or an alarm",
                        \.showWarningBadge
                    )

                    Group {
                        // Shown when there is no VIN too, with the reason. The row used to vanish
                        // entirely, so a reader who had muted a vehicle and then signed out had no
                        // way to unmute it and the list changed length between visits.
                        let hasVehicle = !settingsVehicleVIN.isEmpty
                        let nickname = hasVehicle ? prefs.vehicleNickname(for: settingsVehicleVIN) : ""
                        let carLabel = nickname.isEmpty
                            ? (hasVehicle ? String(settingsVehicleVIN.suffix(6)) : "")
                            : String(nickname.prefix(24))
                        notificationRow(
                            symbol: "bell.slash.fill",
                            title: "Mute This Vehicle",
                            detail: hasVehicle
                                ? "Silence banners for \(carLabel) while telemetry keeps updating"
                                : "Choose a vehicle first; muting applies to one car at a time.",
                            isOn: Binding(
                                get: { prefs.isMuted(vin: settingsVehicleVIN) },
                                set: { enabled in
                                    prefs.setMuted(enabled, for: settingsVehicleVIN)
                                    Notifier.shared?.vehicleMuteDidChange(vin: settingsVehicleVIN)
                                    binder.bump()
                                    binder.notify(.notifications)
                                }
                            )
                        )
                    }

                    Button {
                        Notifier.shared?.sendTestNotification()
                    } label: {
                        Label(L10n.text("Send Test Notification"), systemImage: "bell.and.waves.left.and.right")
                            .hisType(.caption, weight: .medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Divider().opacity(HisingenTheme.dividerOpacity)
                        .padding(.vertical, 2)

                    notificationRow(
                        symbol: "eye.slash.fill",
                        title: "Private Notification Banners",
                        detail: "Hide license plate and battery % from lock screen",
                        \.privateNotificationDetails
                    )
                    }
                    // A master switch that says it governs "every local alert below" has to govern
                    // them: disabled, and dimmed so the reason is visible rather than inferred from
                    // taps that do nothing. Its own row stays live, or it could never be turned
                    // back on.
                    .disabled(!prefs.features.contains(.notifications))
                    .opacity(prefs.features.contains(.notifications) ? 1 : 0.45)
                    .hisAnimation(Motion.stateChange,
                                  value: prefs.features.contains(.notifications))
                }
                // Preference writes go through the binder with no transaction; these
                // bindings give each dependent row its reveal/settle animation.
                .hisAnimation(Motion.layout, value: prefs.notifyOpeningsLeftOpen)
                .hisAnimation(Motion.layout, value: prefs.notifyPlugInReminder)
                .hisAnimation(Motion.layout, value: prefs.notifyLowBattery)
                .hisAnimation(Motion.layout, value: prefs.notifyEveningUnlocked)
                .hisAnimation(Motion.layout, value: prefs.quietHoursEnabled)
            }
            .hisAnimation(Motion.entrance, value: notificationPermission)
        }
    }

    private func notificationRow(
        symbol: String,
        title: String,
        detail: String,
        _ keyPath: ReferenceWritableKeyPath<PreferencesStore, Bool>
    ) -> some View {
        notificationRow(symbol: symbol, title: title, detail: detail, isOn: binder(keyPath, .notifications))
    }

    private func notificationRow(
        symbol: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> NotificationToggleRow {
        NotificationToggleRow(symbol: symbol, title: title, detail: detail, isOn: isOn)
    }

    private func notificationThresholdRow(
        title: String,
        _ keyPath: ReferenceWritableKeyPath<PreferencesStore, Int>,
        values: [Int],
        label: @escaping (Int) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .hisType(.label)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title).hisType(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: binder(keyPath, .notifications)) {
                ForEach(values, id: \.self) { value in Text(label(value)).tag(value) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 90)
            .accessibilityLabel(title)
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
    }
}
