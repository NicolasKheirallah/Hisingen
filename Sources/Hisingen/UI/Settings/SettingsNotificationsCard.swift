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
    var plannerAlertsOnly = false

    private var prefs: PreferencesStore { binder.preferences }
    private var settingsVehicleVIN: String { state?.identity.vin ?? prefs.vin }

    /// Toggle-dependent rows slide down under their switch; opacity keeps the
    /// insertion from reading as a pop.
    private static let dependentRowTransition: AnyTransition =
        .opacity.combined(with: .move(edge: .top))

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bell.badge", title: plannerAlertsOnly ? L10n.text("Charging Planner Alerts") : L10n.text("Notifications"), color: HisingenTheme.semanticWarning)

                permissionBanner

                VStack(spacing: 4) {
                    masterSwitchRow

                    Group {
                        if !plannerAlertsOnly {
                            chargingAlertRows
                        }
                        if prefs.hasPriceSource {
                            if plannerAlertsOnly {
                                plannerAlertRows
                            } else {
                                plannerAlertRows.id(SettingsDestination.plannerAlerts)
                            }
                        }
                        if !plannerAlertsOnly {
                            vehicleAlertRows
                            serviceAndTelemetryRows
                            environmentRows
                            summaryRows
                            soundAndQuietRows
                            badgeAndMuteRows
                            testAndPrivacyRows
                        }
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
                .hisAnimation(Motion.layout, value: prefs.notifyDailySummary)
                .hisAnimation(Motion.layout, value: prefs.quietHoursEnabled)
            }
            .hisAnimation(Motion.entrance, value: notificationPermission)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var permissionBanner: some View {
        if notificationPermission == .denied {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash")
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
                .buttonStyle(.hisSecondary)
                .controlSize(.mini)
            }
            .padding(8)
            .background(HisingenTheme.semanticWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: 0))
            .accessibilityElement(children: .combine)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var masterSwitchRow: some View {
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
    }

    @ViewBuilder
    private var chargingAlertRows: some View {
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
    }

    private var plannerAlertRows: some View {
        VStack(spacing: 4) {
            notificationRow(
                symbol: "clock",
                title: "Notify When the Cheap Window Opens",
                detail: "One banner per window, respecting quiet hours",
                \.notifyPlannerWindowStart
            )

            if prefs.notifyPlannerWindowStart {
                let standardLeadTimes = [0, 15, 30, 60]
                let currentLeadTime = prefs.plannerWindowLeadMinutes
                let leadTimes = standardLeadTimes.contains(currentLeadTime)
                    ? standardLeadTimes : (standardLeadTimes + [currentLeadTime]).sorted()
                Picker(L10n.text("Lead Time"), selection: binder(\.plannerWindowLeadMinutes, .notifications)) {
                    ForEach(leadTimes, id: \.self) { minutes in
                        Text(plannerLeadLabel(minutes)).tag(minutes)
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            notificationRow(
                symbol: "calendar",
                title: "Notify When Tomorrow's Prices Arrive",
                detail: L10n.format("One daily banner after %@ with the cheapest hour", Format.clockTime(hour: 14, minute: 15)),
                \.notifyPlannerPricesPublished
            )

            // A threshold is only meaningful against a price that moves. Fixed-rate readers see
            // the row once they switch to automatic pricing.
            if prefs.electricityRateMode == .automatic {
                notificationRow(
                    symbol: "tag",
                    title: "Price Threshold Alert",
                    detail: "Alert when the current or next hour's price crosses a level you set",
                    isOn: binder(\.notifyPriceThreshold, .notifications)
                )
                if prefs.notifyPriceThreshold {
                    priceThresholdRows
                        .transition(Self.dependentRowTransition)
                }
            }
        }
        .hisAnimation(Motion.layout, value: prefs.notifyPlannerWindowStart)
        .hisAnimation(Motion.layout, value: prefs.notifyPriceThreshold)
    }

    @ViewBuilder
    private var priceThresholdRows: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .hisType(.label)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(L10n.format("Price level, %@/kWh", prefs.currencySymbol))
                .hisType(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TextField("", value: binder(\.priceAlertThresholdSekPerKwh, .notifications),
                      format: .number.precision(.fractionLength(2)))
                .hisField()
                .frame(width: 76)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(L10n.format("Price level, %@/kWh", prefs.currencySymbol))
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)

        HStack(spacing: 8) {
            Image(systemName: "timer")
                .hisType(.label)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(L10n.text("Quiet period"))
                .hisType(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: binder(\.priceAlertQuietMinutes, .notifications)) {
                ForEach([15, 30, 60, 120, 180, 360, 720], id: \.self) { minutes in
                    Text(L10n.format("%d min", minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Quiet period"))
            .controlSize(.small)
            .frame(maxWidth: 100)
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)

        Text(prefs.priceAlertThresholdSekPerKwh > 0
             ? L10n.text("Compared with the price you pay under Electricity settings. One alert per crossing, then quiet for the period above.")
             : L10n.text("Enter a price level to start alerts."))
            .hisType(.micro)
            .foregroundStyle(HisingenTheme.inkMuted)
            .hisCaptionLeading()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 28)
    }

    private func plannerLeadLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return L10n.text("When the window opens")
        case 60: return L10n.text("1 hour before")
        default: return L10n.format("%d minutes before", minutes)
        }
    }

    @ViewBuilder
    private var vehicleAlertRows: some View {
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
            symbol: "bolt.car",
            title: "Left in Convenience Mode",
            detail: "Alert after 30 minutes in convenience mode, which keeps systems on and drains the 12 V battery",
            \.notifyUsageModeConvenience
        )
    }

    @ViewBuilder
    private var serviceAndTelemetryRows: some View {
        notificationRow(
            symbol: "wrench.and.screwdriver",
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
            symbol: "powerplug",
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
            pluginReminderAutomationRow
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
                .accessibilityLabel(L10n.text("Low battery alert threshold"))
                .controlSize(.small)
                .frame(maxWidth: 80)
            }
            .padding(.leading, 12)
            .padding(.vertical, 2)
            .transition(Self.dependentRowTransition)
        }
    }

    @ViewBuilder
    private var environmentRows: some View {
        Divider().opacity(HisingenTheme.dividerOpacity)
            .padding(.vertical, 2)

        notificationRow(
            symbol: "cloud.rain",
            title: "Rain Alert (Windows Open)",
            detail: "Alert if rain starts while windows or sunroof are open",
            \.notifyRainWithWindowsOpen
        )

        notificationRow(
            symbol: "lock.shield",
            title: "Evening Unlocked Reminder",
            detail: L10n.format("Alert if parked and unlocked after %@", Format.clockTime(hour: prefs.eveningUnlockedStartHour)),
            \.notifyEveningUnlocked
        )
        if prefs.notifyEveningUnlocked {
            notificationThresholdRow(
                title: L10n.text("Evening reminder starts"),
                \.eveningUnlockedStartHour,
                values: Array(18...23),
                label: { Format.clockTime(hour: $0) }
            )
            .transition(Self.dependentRowTransition)
        }
    }

    @ViewBuilder
    private var summaryRows: some View {
        Divider().opacity(HisingenTheme.dividerOpacity)
            .padding(.vertical, 2)

        notificationRow(
            symbol: "list.bullet.rectangle",
            title: "Daily Summary",
            detail: "One notification a day with battery, range, charging, warnings, service and failed commands",
            \.notifyDailySummary
        )
        if prefs.notifyDailySummary {
            notificationThresholdRow(
                title: L10n.text("Summary time"),
                \.dailySummaryHour,
                values: Array(0..<24),
                label: { Format.clockTime(hour: $0) }
            )
            .transition(Self.dependentRowTransition)
        }
    }

    @ViewBuilder
    private var soundAndQuietRows: some View {
        Divider().opacity(HisingenTheme.dividerOpacity)
            .padding(.vertical, 2)

        notificationRow(
            symbol: "speaker.wave.2",
            title: "Notification Sounds",
            detail: "Play a sound on urgent alerts: alarms, warnings and charging problems",
            \.notifySounds
        )

        notificationRow(
            symbol: "moon.zzz",
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
                        Text(Format.clockTime(hour: h)).tag(h)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Quiet hours start time"))
                .controlSize(.small)
                .frame(maxWidth: 76)
                Text(L10n.text("to"))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
                Picker("", selection: binder(\.quietHoursEndHour, .notifications)) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(Format.clockTime(hour: h)).tag(h)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Quiet hours end time"))
                .controlSize(.small)
                .frame(maxWidth: 76)
            }
            .padding(.leading, 12)
            .padding(.vertical, 2)
            .transition(Self.dependentRowTransition)
        }
    }

    @ViewBuilder
    private var badgeAndMuteRows: some View {
        notificationRow(
            symbol: "app.badge.fill",
            title: "Warning Badge",
            // A badge on a hidden tile paints nothing, so the row says what it needs instead
            // of reading as broken. The badge shows once the Dock icon is on.
            detail: prefs.showDockIcon
                ? "Show a dock badge while any vehicle reports warnings or an alarm"
                : "Show a dock badge while any vehicle reports warnings or an alarm. Turn on the Dock icon (Appearance → Menu Bar) for the badge to show.",
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
                symbol: "bell.slash",
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
    }

    @ViewBuilder
    private var testAndPrivacyRows: some View {
        Button {
            Notifier.shared?.sendTestNotification()
        } label: {
            Label(L10n.text("Send Test Notification"), systemImage: "bell.and.waves.left.and.right")
                .hisType(.caption, weight: .medium)
        }
        .buttonStyle(.hisSecondary)
        .controlSize(.small)

        Divider().opacity(HisingenTheme.dividerOpacity)
            .padding(.vertical, 2)

        notificationRow(
            symbol: "eye.slash",
            title: "Private Notification Banners",
            detail: "Hide license plate and battery % from lock screen",
            \.privateNotificationDetails
        )
    }

    // MARK: - Row builders

    /// Opt-in for the Reminders write-back on the plug-in alert. The preference rides
    /// with the Reminders integration rather than in `PreferencesStore` because the
    /// persistence layer is being reworked in another session; the key follows the
    /// same UserDefaults pattern and should move to the notifications preferences
    /// with the rest.
    private var pluginReminderAutomationRow: some View {
        notificationRow(
            symbol: "reminder",
            title: "Also Add to Reminders",
            detail: "Write a Reminder through macOS Reminders each time the plug-in alert fires",
            isOn: Binding(
                get: { ReminderWriter.pluginAutomationEnabled(in: UserDefaults.standard) },
                set: { enabled in
                    ReminderWriter.setPluginAutomation(enabled, in: UserDefaults.standard)
                    if enabled {
                        // The toggle press is the user gesture EventKit needs for its
                        // access prompt; a refusal snaps the toggle back off.
                        Task { @MainActor in
                            guard await ReminderWriter.shared.requestAccessIfNeeded() else {
                                ReminderWriter.setPluginAutomation(false, in: UserDefaults.standard)
                                binder.bump()
                                return
                            }
                            binder.bump()
                        }
                    }
                }
            )
        )
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
