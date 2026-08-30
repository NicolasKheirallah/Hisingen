import AppKit
import SwiftUI

extension InfoTabView {
    // MARK: - Hero visual

    var heroVisualSection: some View {
        let isInterior = selectedAngleIndex == -1
        let currentImageData: Data? = {
            if isInterior {
                return state.interiorImageData ?? imageCache.interiorImage(for: state.vin)
            }
            return imageCache.image(for: state.vin, angle: selectedAngleIndex)
                 ?? (selectedAngleIndex == preferences.carRenderAngle.rawValue ? state.imageData : nil)
        }()

        let exteriorAngles = availableExteriorAngles
        let supportsMultipleAngles = exteriorAngles.count > 1
        let hasInterior = (state.interiorImageData != nil)
            || (imageCache.interiorImage(for: state.vin) != nil)
        let angleTitle = CarRenderAngle(rawValue: selectedAngleIndex)?.title ?? L10n.text("Exterior")

        return Card {
            VStack(spacing: 12) {
                // Angle & Interior View Switcher
                if supportsMultipleAngles || hasInterior {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                if supportsMultipleAngles {
                                    ForEach(exteriorAngles, id: \.self) { angle in
                                        angleButton(title: angle.title, angle: angle.rawValue, icon: angle.symbol, proxy: proxy)
                                    }
                                } else {
                                    let exteriorAngle = exteriorAngles.first?.rawValue ?? preferences.carRenderAngle.rawValue
                                    angleButton(title: L10n.text("Exterior"), angle: exteriorAngle, icon: "car.side.fill", proxy: proxy)
                                }
                                if hasInterior {
                                    angleButton(title: L10n.text("Interior"), angle: -1, icon: "carseat.left.fill", proxy: proxy)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }
                    }
                    .zIndex(10)
                }

                if let currentImageData {
                    ZStack {
                        RadialGradient(
                            colors: [Color.primary.opacity(0.06), Color.clear],
                            center: .center,
                            startRadius: 40,
                            endRadius: 170
                        )
                        .allowsHitTesting(false)

                        VehiclePresentationView(
                            identity: VehiclePresentationIdentity(vin: state.vin, angle: selectedAngleIndex),
                            imageData: currentImageData
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, -HisingenTheme.cardPadding)
                    .padding(.top, -4)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { openImageInPreview(currentImageData) }
                    .contextMenu {
                        Button {
                            copyImage(currentImageData)
                        } label: {
                            Label(L10n.text("Copy Image"), systemImage: "doc.on.doc")
                        }
                        Button {
                            saveImage(currentImageData)
                        } label: {
                            Label(L10n.text("Save Image…"), systemImage: "square.and.arrow.down")
                        }
                        Button {
                            openImageInPreview(currentImageData)
                        } label: {
                            Label(L10n.text("View Full Size"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(isInterior
                        ? L10n.text("Interior view of the vehicle")
                        : L10n.format("%@ studio render", angleTitle))
                    .accessibilityHint(L10n.text("Activate to open the full-size image"))
                    .accessibilityAddTraits(.isButton)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                            .frame(height: 120)
                        VStack(spacing: 6) {
                            Image(systemName: isInterior ? "carseat.left.fill" : "car.side.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(HisingenTheme.accent.opacity(0.7))
                            Text(isInterior ? L10n.text("Interior View") : L10n.text("Studio Render"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .allowsHitTesting(false)
                }

                let primaryTitle = preferences.formattedVehicleTitle(
                    vin: state.vin,
                    modelName: state.modelName,
                    modelYear: state.modelYear,
                    registrationNo: state.registrationNo
                )
                let showRegBadge: Bool = {
                    guard let reg = state.registrationNo, !reg.isEmpty else { return false }
                    return preferences.vehicleLabelFormat != .registration
                        && preferences.vehicleLabelFormat != .nicknameAndRegistration
                        && preferences.vehicleLabelFormat != .registrationAndModel
                }()
                let subtitleText: String? = {
                    switch preferences.vehicleLabelFormat {
                    case .registration, .nickname, .nicknameAndRegistration:
                        let model = state.modelName
                        let year = state.modelYear.map { L10n.format("Model Year %@", $0) }
                        let combined = [model, year].compactMap { $0 }.joined(separator: " · ")
                        return combined.isEmpty ? nil : combined
                    case .modelAndYear, .modelOnly, .registrationAndModel:
                        if let year = state.modelYear {
                            return L10n.format("Model Year %@", year)
                        }
                        return nil
                    }
                }()

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(primaryTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(HisingenTheme.ink)
                            if let color = state.externalColour, !color.isEmpty && !isInterior {
                                Pill(
                                    text: color,
                                    color: HisingenTheme.accent,
                                    symbol: "paintpalette.fill"
                                )
                            } else if isInterior, let upholstery = state.upholstery, !upholstery.isEmpty {
                                Pill(
                                    text: upholstery,
                                    color: HisingenTheme.accent,
                                    symbol: "carseat.left.fill"
                                )
                            }
                        }
                        if let subtitleText, !subtitleText.isEmpty {
                            Text(subtitleText)
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                    Spacer()
                    if showRegBadge, let reg = state.registrationNo, !reg.isEmpty {
                        Text(reg)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    func angleButton(title: String, angle: Int, icon: String, proxy: ScrollViewProxy? = nil) -> some View {
        let isSelected = selectedAngleIndex == angle
        return Button {
            withAnimation(.easeInOut(duration: Motion.fast)) {
                selectedAngleIndex = angle
                proxy?.scrollTo(angle, anchor: .center)
            }
            // Persist the exterior angle so re-opening the tab restores the last-viewed pose.
            if angle >= 0, let resolved = CarRenderAngle(rawValue: angle) {
                preferences.carRenderAngle = resolved
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? HisingenTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? HisingenTheme.accent : HisingenTheme.inkMuted)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .withoutFocusRing()
        .id(angle)
    }

    // MARK: - Hero image actions

    func copyImage(_ data: Data?) {
        guard let data, let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Opens the render at full resolution in the system image viewer — reliable from inside a
    /// menu-bar popover, where an in-app sheet/overlay cannot size itself to the viewport.
    func openImageInPreview(_ data: Data?) {
        guard let data, let image = NSImage(data: data) else { return }
        let ext: String
        let payload: Data
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            payload = png
            ext = "png"
        } else {
            payload = data
            ext = "img"
        }
        let name = "\(state.model.displayName.replacingOccurrences(of: " ", with: "_"))_render.\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try payload.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            reportError = error.localizedDescription
        }
    }

    func saveImage(_ data: Data?) {
        guard let data, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            reportError = L10n.text("The image could not be prepared for saving.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(state.model.displayName.replacingOccurrences(of: " ", with: "_"))_render.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            } catch {
                reportError = error.localizedDescription
            }
        }
    }
}
