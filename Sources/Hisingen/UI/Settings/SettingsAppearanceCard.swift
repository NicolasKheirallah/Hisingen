import SwiftUI

@MainActor
struct SettingsAppearanceCard: View {
    var state: VehicleState?
    var imageCache: CarImageCache
    let binder: PreferenceBinder

    @State private var appTheme: AppTheme = .hisingen
    @State private var appearanceMode: AppearanceMode = .system
    @State private var carRenderAngle: CarRenderAngle = .frontThreeQuarter
    @State private var panelSize = PanelSize.standard
    @State private var contentDensity = ContentDensity.standard
    @State private var customSizeEnabled = false
    @State private var customWidth: Double = 0
    @State private var customHeight: Double = 0
    @State private var selectedThemeCategory: ThemeCategory = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferences: PreferencesStore { binder.preferences }
    private var settingsVehicleVIN: String { state?.identity.vin ?? preferences.vin }

    private var resolvedLayout: PanelLayout {
        PanelLayout.resolve(
            panelSizeRaw: panelSize.rawValue,
            densityRaw: contentDensity.rawValue,
            customEnabled: customSizeEnabled,
            customWidth: customWidth,
            customHeight: customHeight
        )
    }

    private var availableRenderAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter {
            imageCache.hasImage(for: settingsVehicleVIN, angle: $0.rawValue)
        }
    }

    private var filteredThemes: [AppTheme] {
        if selectedThemeCategory == .all {
            return AppTheme.allCases
        }
        return AppTheme.allCases.filter { $0.category == selectedThemeCategory }
    }

    private func themeCategoryCount(_ category: ThemeCategory) -> Int {
        if category == .all { return AppTheme.allCases.count }
        return AppTheme.allCases.filter { $0.category == category }.count
    }

    private func resetPanelGeometry() {
        panelSize = .standard
        contentDensity = .standard
        customSizeEnabled = false
        customWidth = Double(PanelSize.standard.width)
        customHeight = Double(PanelSize.standard.idealHeight)
        preferences.panelSize = .standard
        preferences.contentDensity = .standard
        preferences.customPanelSizeEnabled = false
        preferences.customPanelWidth = customWidth
        preferences.customPanelHeight = customHeight
        binder.notify(.presentation)
    }

    var body: some View {
        let vehicleLabel = preferences.lastVehicleLabel(for: preferences.activeBrand)
        let availableAngles = availableRenderAngles
        let supportsMultipleAngles = availableAngles.count > 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeader(symbol: "paintpalette.fill", title: L10n.text("Appearance & Themes"), color: HisingenTheme.accent)
                    Spacer()
                    Text(L10n.format("%d Themes", AppTheme.allCases.count))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(HisingenTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(HisingenTheme.accent)
                }

                // Appearance Mode Selector (System / Light / Dark)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Screenshot Privacy Mode"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(HisingenTheme.ink)
                            Text(L10n.text("Blurs VIN, plate and coordinates across the app for safe sharing."))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: binder(\.privacyRedactionEnabled, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Screenshot Privacy Mode"))
                    }
                    .padding(.vertical, 2)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Floating Charging Panel"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(HisingenTheme.ink)
                            Text(L10n.text("Small always-on-top panel with charge progress while plugged in."))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: binder(\.floatingChargingPanelEnabled, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Floating Charging Panel"))
                    }
                    .padding(.vertical, 2)

                    Text(L10n.text("Mode"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HisingenTheme.ink)

                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            let isModeSelected = appearanceMode == mode
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                                    appearanceMode = mode
                                    preferences.appearanceMode = mode
                                }
                                binder.notify(.presentation)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: mode.symbol)
                                        .font(.system(size: 11, weight: isModeSelected ? .semibold : .regular))
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: isModeSelected ? .semibold : .regular))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    isModeSelected ? HisingenTheme.accent.opacity(0.16) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(isModeSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(isModeSelected ? HisingenTheme.accent : HisingenTheme.ink)
                            }
                            .buttonStyle(.plain)
                            .withoutFocusRing()
                        }
                    }
                }

                // Vehicle Image Perspective & Studio Render Preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text(supportsMultipleAngles ? "Vehicle Perspective" : "Vehicle Image"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HisingenTheme.ink)
                        Spacer()
                        if supportsMultipleAngles {
                            Text(carRenderAngle.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Live Studio Render Preview (Async Decoded & Cached)
                    SettingsStudioRenderPreview(
                        vin: settingsVehicleVIN,
                        angle: supportsMultipleAngles ? carRenderAngle.rawValue : (availableAngles.first?.rawValue ?? 0),
                        imageCache: imageCache
                    )

                    if supportsMultipleAngles {
                        let angleChunks = stride(from: 0, to: availableAngles.count, by: 2).map {
                            Array(availableAngles[$0..<min($0 + 2, availableAngles.count)])
                        }
                        VStack(spacing: 8) {
                            ForEach(0..<angleChunks.count, id: \.self) { rowIdx in
                                let row = angleChunks[rowIdx]
                                HStack(spacing: 8) {
                                    ForEach(row, id: \.self) { angle in
                                        let isAngleSelected = carRenderAngle == angle
                                        Button {
                                            withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                                                carRenderAngle = angle
                                                preferences.carRenderAngle = angle
                                            }
                                            binder.notify(.presentation)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: angle.symbol)
                                                    .font(.system(size: 11, weight: isAngleSelected ? .semibold : .regular))
                                                Text(angle.title)
                                                    .font(.system(size: 11, weight: isAngleSelected ? .semibold : .regular))
                                                    .lineLimit(1)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 4)
                                            .background(
                                                isAngleSelected ? HisingenTheme.accent.opacity(0.16) : Color.primary.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .stroke(isAngleSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                            )
                                            .foregroundStyle(isAngleSelected ? HisingenTheme.accent : HisingenTheme.ink)
                                        }
                                        .buttonStyle(.plain)
                                        .withoutFocusRing()
                                    }
                                    if row.count == 1 {
                                        Spacer().frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                Text(L10n.format("Active for %@ — each vehicle saves its own theme preference.", vehicleLabel))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                // Category Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ThemeCategory.allCases, id: \.self) { cat in
                            categoryFilterButton(cat)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // 2-Column Responsive Grid of Themes
                let themeChunks = stride(from: 0, to: filteredThemes.count, by: 2).map {
                    Array(filteredThemes[$0..<min($0 + 2, filteredThemes.count)])
                }
                VStack(spacing: 8) {
                    ForEach(0..<themeChunks.count, id: \.self) { rowIdx in
                        let row = themeChunks[rowIdx]
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { theme in
                                themeTile(theme)
                            }
                            if row.count == 1 {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                Text(L10n.text("Monochrome Precision and Heritage Blue are independent themes based on publicly documented design principles from Polestar and Volvo Cars. No affiliation or endorsement is implied."))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(L10n.text("Panel Size"))
                                        .font(.system(size: 12, weight: .medium))
                                    if customSizeEnabled {
                                        Text(L10n.text("Custom"))
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(HisingenTheme.accent.opacity(0.14), in: Capsule())
                                            .foregroundStyle(HisingenTheme.accent)
                                    }
                                }
                                Text(L10n.text("Dropdown panel preset — applies instantly"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $panelSize) {
                                ForEach(PanelSize.allCases, id: \.self) { size in
                                    Text(size.title).tag(size)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                            .onChange(of: panelSize) { _, newSize in
                                preferences.panelSize = newSize
                                // A picked preset replaces any custom override.
                                customSizeEnabled = false
                                preferences.customPanelSizeEnabled = false
                                binder.notify(.presentation)
                            }
                        }

                        SegmentedPresetRow(options: PanelSize.allCases, selection: $panelSize)
                            .onChange(of: panelSize) { _, newSize in
                                preferences.panelSize = newSize
                                customSizeEnabled = false
                                preferences.customPanelSizeEnabled = false
                                binder.notify(.presentation)
                            }

                        PanelCustomSizeControls(
                            isEnabled: $customSizeEnabled,
                            width: $customWidth,
                            height: $customHeight,
                            seedValues: { [panelSize] in
                                (Double(panelSize.width), Double(panelSize.idealHeight))
                            },
                            onCommit: {
                                preferences.customPanelSizeEnabled = customSizeEnabled
                                preferences.customPanelWidth = customWidth
                                preferences.customPanelHeight = customHeight
                                binder.notify(.presentation)
                            }
                        )

                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text(L10n.text("Current:"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "ruler")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HisingenTheme.accent)
                                Text(resolvedLayout.dimensionsLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            PanelProportionPreview(layout: resolvedLayout)
                            Button {
                                resetPanelGeometry()
                            } label: {
                                Text(L10n.text("Reset Sizes"))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(L10n.text("Back to Standard panel and density"))
                        }
                        .padding(.vertical, 2)
                    }

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("Content Density"))
                                    .font(.system(size: 12, weight: .medium))
                                Text(L10n.text("Zoom content independently of panel size — compact shows more before scrolling"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $contentDensity) {
                                ForEach(ContentDensity.allCases, id: \.self) { density in
                                    Text(density.title).tag(density)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                            .onChange(of: contentDensity) { _, newDensity in
                                preferences.contentDensity = newDensity
                                binder.notify(.presentation)
                            }
                        }

                        SegmentedPresetRow(options: ContentDensity.allCases, selection: $contentDensity)
                            .onChange(of: contentDensity) { _, newDensity in
                                preferences.contentDensity = newDensity
                                binder.notify(.presentation)
                            }

                        HStack(spacing: 6) {
                            Text(L10n.text("Current:"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HisingenTheme.accent)
                                Text(String(format: "%.0f%%", contentDensity.scale * 100))
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                Text("· " + contentDensity.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
            }
        }
        .onAppear {
            appTheme = preferences.appTheme
            appearanceMode = preferences.appearanceMode
            carRenderAngle = preferences.carRenderAngle
            if let firstAvailable = availableRenderAngles.first,
               !availableRenderAngles.contains(preferences.carRenderAngle) {
                carRenderAngle = firstAvailable
                preferences.carRenderAngle = firstAvailable
            }
            panelSize = preferences.panelSize
            contentDensity = preferences.contentDensity
            customSizeEnabled = preferences.customPanelSizeEnabled
            customWidth = preferences.customPanelWidth > 0
                ? preferences.customPanelWidth
                : Double(PanelSize.standard.width)
            customHeight = preferences.customPanelHeight > 0
                ? preferences.customPanelHeight
                : Double(PanelSize.standard.idealHeight)
        }
    }

    private func categoryFilterButton(_ cat: ThemeCategory) -> some View {
        let isSelected = selectedThemeCategory == cat
        let count = themeCategoryCount(cat)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                selectedThemeCategory = cat
            }
        } label: {
            HStack(spacing: 4) {
                Text(cat.title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.85)
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(isSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? HisingenTheme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func themeTile(_ theme: AppTheme) -> some View {
        let isSelected = appTheme == theme
        let accentColor = Color(hex: theme.accentColorHex) ?? HisingenTheme.accent
        return Button {
            guard appTheme != theme else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                appTheme = theme
                preferences.appTheme = theme
            }
            binder.notify(.presentation)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(theme.previewHexColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? Color.gray)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accentColor)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            .frame(width: 12, height: 12)
                    }
                }

                Text(theme.title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                Text(theme.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.title): \(theme.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

@MainActor
struct SettingsStudioRenderPreview: View {
    let vin: String
    let angle: Int
    let imageCache: CarImageCache
    @State private var artwork: VehicleArtworkStore.Artwork?

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.primary.opacity(0.05), Color.clear],
                center: .center,
                startRadius: 30,
                endRadius: 140
            )

            if let cgImage = artwork?.image {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(1.22, anchor: .center)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 165)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .task(id: "\(vin)#\(angle)") {
            let store = VehicleArtworkStore.shared
            let budget = 600
            let source = VehicleArtworkStore.source(vin: vin, angle: angle)
            if let data = imageCache.image(for: vin, angle: angle) ?? imageCache.image(for: vin) {
                if let cached = store.cached(source: source, data: data, pixelBudget: budget) {
                    artwork = cached
                } else {
                    artwork = await store.artwork(source: source, data: data, pixelBudget: budget)
                }
            }
        }
    }
}
