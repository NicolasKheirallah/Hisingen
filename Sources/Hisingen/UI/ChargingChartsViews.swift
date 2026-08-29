import SwiftUI


enum CurveMode: String, CaseIterable, Identifiable {
    case soc = "SoC %"
    case power = "Power kW"
    case dual = "Dual"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .soc: return L10n.text("SoC %")
        case .power: return L10n.text("Power kW")
        case .dual: return L10n.text("Dual")
        }
    }
}

@MainActor
struct ChargingCurveView: View {
    let samples: [ChargingSample]
    let targetPercentage: Int?
    let readyDate: Date?
    let isLive: Bool
    var currentPowerWatts: Int? = nil
    var energySource: ChargingSessionEnergySource? = nil
    var confidence: ChargingSessionConfidence? = nil
    var sampleCoverage: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint? = nil
    @State private var curveMode: CurveMode = .soc

    private var hasPowerData: Bool {
        samples.contains { ($0.powerWatts ?? 0) > 0 } || (currentPowerWatts ?? 0) > 0
    }

    private var startSample: ChargingSample { samples.first ?? ChargingSample(batteryPercentage: 0) }
    private var lastSample: ChargingSample { samples.last ?? startSample }
    private var effectiveTargetPct: Double? {
        targetPercentage.map(Double.init) ?? (isLive && readyDate != nil ? 100.0 : nil)
    }

    private var peakWatts: Int {
        let samplePeaks = samples.compactMap(\.powerWatts).max() ?? 0
        return max(samplePeaks, currentPowerWatts ?? 0)
    }

    private var averageWatts: Int {
        let valid = samples.compactMap(\.powerWatts).filter { $0 > 0 }
        guard !valid.isEmpty else { return currentPowerWatts ?? 0 }
        return valid.reduce(0, +) / valid.count
    }

    private var socDomain: (low: Double, high: Double) {
        var values = samples.map(\.batteryPercentage)
        if let effectiveTargetPct { values.append(effectiveTargetPct) }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 100
        let span = max(8.0, maxV - minV)
        let padding = max(2.5, span * 0.12)
        let low = max(0, minV - padding)
        let high = min(100, maxV + padding)
        return (low, max(low + 1.0, high))
    }

    private var powerDomain: (low: Double, high: Double) {
        let maxKw = Double(max(peakWatts, 7400)) / 1000.0 * 1.15
        return (0.0, max(3.7, maxKw))
    }

    private var timeSpan: (start: Date, end: Date) {
        let start = startSample.timestamp
        let rawEnd = (isLive ? (readyDate ?? lastSample.timestamp) : lastSample.timestamp)
        let end = rawEnd.timeIntervalSince(start) > 60 ? rawEnd : start.addingTimeInterval(60)
        return (start, end)
    }

    private var observationGaps: [ChargingCharts.SampleGap] {
        ChargingCharts.gaps(in: samples)
    }

    private func xCoord(_ date: Date, horizontalInset: CGFloat, chartWidth: CGFloat, timeStart: Date, totalSpan: TimeInterval) -> CGFloat {
        let fraction = CGFloat(date.timeIntervalSince(timeStart) / totalSpan)
        return horizontalInset + min(max(fraction, 0), 1) * chartWidth
    }

    private func yCoord(_ pct: Double, verticalInset: CGFloat, chartHeight: CGFloat, domainLow: Double, domainHigh: Double) -> CGFloat {
        let fraction = CGFloat((pct - domainLow) / (domainHigh - domainLow))
        return verticalInset + (1.0 - min(max(fraction, 0), 1)) * chartHeight
    }

    private var summaryText: String {
        switch curveMode {
        case .power:
            if peakWatts > 0 {
                return String(format: "%@ · %@", Format.kilowatts(watts: peakWatts), L10n.text("Peak"))
            }
            return ""
        case .dual:
            let pctAdded = max(0, lastSample.batteryPercentage - startSample.batteryPercentage)
            if peakWatts > 0 {
                return String(format: "+%.0f%% · %@", pctAdded, Format.kilowatts(watts: peakWatts))
            }
            return String(format: "+%.0f%%", pctAdded)
        case .soc:
            let pctAdded = max(0, lastSample.batteryPercentage - startSample.batteryPercentage)
            if isLive {
                if let effectiveTargetPct, effectiveTargetPct > lastSample.batteryPercentage {
                    return String(format: "%.0f%% → %.0f%%", lastSample.batteryPercentage, effectiveTargetPct)
                }
                if pctAdded >= 0.5 {
                    return String(format: "%.0f%% (+%.0f%%)", lastSample.batteryPercentage, pctAdded)
                }
                return String(format: "%.0f%%", lastSample.batteryPercentage)
            }
            return String(format: "%.0f%% → %.0f%% (+%.0f%%)", startSample.batteryPercentage, lastSample.batteryPercentage, pctAdded)
        }
    }

    var body: some View {
        guard !samples.isEmpty else { return AnyView(EmptyView()) }
        let (domainLow, domainHigh) = socDomain
        let (pwrLow, pwrHigh) = powerDomain
        let (timeStart, timeEnd) = timeSpan
        let totalSpan = max(60, timeEnd.timeIntervalSince(timeStart))

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Label(curveMode == .power ? L10n.text("Power Curve") : L10n.text("Charging Curve"), systemImage: curveMode == .power ? "waveform.path.ecg" : "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if isLive {
                        Circle()
                            .fill(HisingenTheme.semanticGood)
                            .frame(width: 5, height: 5)
                            .opacity(pulse ? 1.0 : 0.45)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                        Text(L10n.text("Live").uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(HisingenTheme.semanticGood)
                    }

                    if hasPowerData {
                        Picker("", selection: $curveMode) {
                            ForEach(CurveMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 140)
                    }

                    Spacer()
                    Text(summaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(curveMode == .power ? Color.green : HisingenTheme.accent)
                }

                if let energySource, let confidence {
                    HStack(spacing: 5) {
                        Label("\(confidence.displayName) · \(energySource.displayName)",
                              systemImage: "checkmark.seal")
                        if let sampleCoverage {
                            Text("· " + L10n.format("%d%% observed", Int((sampleCoverage * 100).rounded())))
                                .monospacedDigit()
                        }
                        Spacer()
                        if !observationGaps.isEmpty {
                            Label(L10n.format("%d observation gaps", observationGaps.count),
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    let height = geo.size.height
                    let horizontalInset: CGFloat = 8
                    let verticalInset: CGFloat = 7
                    let chartWidth = max(1, width - horizontalInset * 2)
                    let chartHeight = max(1, height - verticalInset * 2)
                    let bottomY = verticalInset + chartHeight

                    let socPointSegments = ChargingCharts.contiguousSegments(samples).map { segment in
                        segment.map { sample in
                            CGPoint(
                                x: xCoord(sample.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: yCoord(sample.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            )
                        }
                    }
                    let socPoints = socPointSegments.flatMap { $0 }

                    let powerSamples = samples.enumerated().compactMap { index, sample -> ChargingSample? in
                        let watts = sample.powerWatts ?? (index == samples.count - 1 ? currentPowerWatts : nil)
                        guard let watts, watts > 0 else { return nil }
                        return ChargingSample(
                            timestamp: sample.timestamp, batteryPercentage: sample.batteryPercentage,
                            powerWatts: watts, chargingType: sample.chargingType
                        )
                    }
                    let powerPointSegments = ChargingCharts.contiguousSegments(powerSamples).map { segment in
                        segment.map { sample in
                            CGPoint(
                                x: xCoord(sample.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: yCoord(Double(sample.powerWatts ?? 0) / 1000.0, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh)
                            )
                        }
                    }
                    let powerPoints = powerPointSegments.flatMap { $0 }

                    let firstSocPoint = socPoints.first ?? CGPoint(x: horizontalInset, y: yCoord(startSample.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh))
                    let lastSocPoint = socPoints.last ?? firstSocPoint
                    let firstPowerPoint = powerPoints.first ?? CGPoint(x: horizontalInset, y: bottomY)
                    let lastPowerPoint = powerPoints.last ?? firstPowerPoint

                    let projectedEnd: CGPoint? = {
                        guard isLive, curveMode != .power, let readyDate, let effectiveTargetPct, effectiveTargetPct > lastSample.batteryPercentage else { return nil }
                        return CGPoint(
                            x: xCoord(readyDate, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                            y: yCoord(effectiveTargetPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                        )
                    }()

                    let hoverInfo: (point: CGPoint, pct: Double, date: Date, powerWatts: Int?, isProjected: Bool)? = {
                        guard isHovering, let hoverPos = hoverLocation else { return nil }
                        let clampedX = min(max(hoverPos.x, horizontalInset), width - horizontalInset)
                        let timeFrac = Double((clampedX - horizontalInset) / chartWidth)
                        let hoveredDate = timeStart.addingTimeInterval(timeFrac * totalSpan)

                        if hoveredDate <= lastSample.timestamp || projectedEnd == nil {
                            let closest = samples.min(by: { abs($0.timestamp.timeIntervalSince(hoveredDate)) < abs($1.timestamp.timeIntervalSince(hoveredDate)) }) ?? lastSample
                            let resolvedWatts = closest.powerWatts
                                ?? (closest.timestamp == lastSample.timestamp ? currentPowerWatts : nil)
                            let kw = Double(resolvedWatts ?? 0) / 1000.0
                            let targetY = curveMode == .power ? yCoord(kw, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh) : yCoord(closest.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            let pt = CGPoint(
                                x: xCoord(closest.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: targetY
                            )
                            return (pt, closest.batteryPercentage, closest.timestamp, resolvedWatts, false)
                        } else if let readyDate, let effectiveTargetPct {
                            let projTotal = readyDate.timeIntervalSince(lastSample.timestamp)
                            let projElapsed = hoveredDate.timeIntervalSince(lastSample.timestamp)
                            let projFrac = projTotal > 0 ? min(max(projElapsed / projTotal, 0), 1) : 1.0
                            let interpPct = lastSample.batteryPercentage + projFrac * (effectiveTargetPct - lastSample.batteryPercentage)
                            let pt = CGPoint(
                                x: xCoord(hoveredDate, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: yCoord(interpPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            )
                            return (pt, interpPct, hoveredDate, nil, true)
                        }
                        return nil
                    }()

                    ZStack {
                        ForEach(observationGaps.indices, id: \.self) { index in
                            let gap = observationGaps[index]
                            let startX = xCoord(gap.startedAt, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan)
                            let endX = xCoord(gap.endedAt, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan)
                            Rectangle()
                                .fill(Color.orange.opacity(0.055))
                                .frame(width: max(2, endX - startX), height: chartHeight)
                                .position(x: (startX + endX) / 2, y: verticalInset + chartHeight / 2)
                        }

                        if curveMode != .power, let effectiveTargetPct {
                            let guideY = yCoord(effectiveTargetPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            Path { path in
                                path.move(to: CGPoint(x: horizontalInset, y: guideY))
                                path.addLine(to: CGPoint(x: width - horizontalInset, y: guideY))
                            }
                            .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                            Text(L10n.format("Target %d%%", Int(effectiveTargetPct)))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(.regularMaterial, in: Capsule())
                                .position(x: max(32, width - 36), y: max(verticalInset + 4, guideY - 9))
                        }

                        if (curveMode == .power || curveMode == .dual) && averageWatts > 0 {
                            let avgKw = Double(averageWatts) / 1000.0
                            let avgY = yCoord(avgKw, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh)
                            Path { path in
                                path.move(to: CGPoint(x: horizontalInset, y: avgY))
                                path.addLine(to: CGPoint(x: width - horizontalInset, y: avgY))
                            }
                            .stroke(Color.green.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }

                        if curveMode == .soc || curveMode == .dual {
                            if let projectedEnd {
                                Path { path in
                                    path.move(to: lastSocPoint)
                                    path.addLine(to: projectedEnd)
                                    path.addLine(to: CGPoint(x: projectedEnd.x, y: bottomY))
                                    path.addLine(to: CGPoint(x: lastSocPoint.x, y: bottomY))
                                    path.closeSubpath()
                                }
                                .fill(
                                    LinearGradient(
                                        colors: [HisingenTheme.accent.opacity(0.10), HisingenTheme.accent.opacity(0.01)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                            }

                            ForEach(socPointSegments.indices, id: \.self) { index in
                                let points = socPointSegments[index]
                                if points.count >= 2, let first = points.first, let last = points.last {
                                    ChargingCharts.stepPath(points)
                                        .addingClosedBottom(firstX: first.x, lastX: last.x, bottomY: bottomY)
                                        .fill(
                                            LinearGradient(
                                                colors: [HisingenTheme.accent.opacity(0.25), HisingenTheme.accent.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        )
                                }
                            }

                            if let projectedEnd {
                                Path { path in
                                    path.move(to: lastSocPoint)
                                    path.addLine(to: projectedEnd)
                                }
                                .stroke(HisingenTheme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 4]))

                                Circle()
                                    .strokeBorder(HisingenTheme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                                    .background(Circle().fill(HisingenTheme.accent.opacity(0.18)))
                                    .frame(width: 8, height: 8)
                                    .position(projectedEnd)
                            }

                            ForEach(socPointSegments.indices, id: \.self) { index in
                                let points = socPointSegments[index]
                                if points.count >= 2 {
                                    ChargingCharts.stepPath(points)
                                        .stroke(HisingenTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                        .shadow(color: HisingenTheme.accent.opacity(0.35), radius: 3, y: 1)
                                }
                            }
                        }

                        if curveMode == .power || curveMode == .dual {
                            ForEach(powerPointSegments.indices, id: \.self) { index in
                                let points = powerPointSegments[index]
                                if points.count >= 2, let first = points.first, let last = points.last {
                                    if curveMode == .power {
                                        smoothPath(points)
                                            .addingClosedBottom(firstX: first.x, lastX: last.x, bottomY: bottomY)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.green.opacity(0.3), Color.green.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom
                                                )
                                            )
                                    }

                                    smoothPath(points)
                                        .stroke(
                                            Color.green,
                                            style: StrokeStyle(lineWidth: curveMode == .dual ? 1.8 : 2.2, lineCap: .round, lineJoin: .round, dash: curveMode == .dual ? [4, 3] : [])
                                        )
                                        .shadow(color: Color.green.opacity(0.35), radius: 3, y: 1)
                                }
                            }
                        }

                        if curveMode != .power {
                            Circle()
                                .fill(HisingenTheme.accent.opacity(0.75))
                                .frame(width: 5, height: 5)
                                .position(firstSocPoint)

                            ZStack {
                                if isLive && !reduceMotion {
                                    Circle()
                                        .stroke(HisingenTheme.accent.opacity(pulse ? 0.0 : 0.65), lineWidth: 1.5)
                                        .frame(width: 16, height: 16)
                                        .scaleEffect(pulse ? 1.65 : 0.85)
                                }
                                Circle()
                                    .fill(HisingenTheme.accent)
                                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                                    .frame(width: 7.5, height: 7.5)
                                    .shadow(color: HisingenTheme.accent.opacity(isLive ? (pulse ? 0.75 : 0.35) : 0.25), radius: isLive ? (pulse ? 5 : 2) : 2)
                            }
                            .position(lastSocPoint)
                        } else {
                            Circle()
                                .fill(Color.green)
                                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                                .frame(width: 7.5, height: 7.5)
                                .position(lastPowerPoint)
                        }

                        if let info = hoverInfo {
                            Path { path in
                                path.move(to: CGPoint(x: info.point.x, y: verticalInset))
                                path.addLine(to: CGPoint(x: info.point.x, y: bottomY))
                            }
                            .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                            Circle()
                                .fill(curveMode == .power ? Color.green : HisingenTheme.accent)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .frame(width: 9, height: 9)
                                .shadow(color: (curveMode == .power ? Color.green : HisingenTheme.accent).opacity(0.6), radius: 4)
                                .position(info.point)

                            HStack(spacing: 4) {
                                Text(String(format: "%.0f%%", info.pct))
                                    .font(.system(size: 9, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(HisingenTheme.accent)
                                if let watts = info.powerWatts, watts > 0 {
                                    Text("· \(Format.kilowatts(watts: watts))")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.green)
                                }
                                Text("· " + Format.shortTime(date: info.date))
                                    .font(.system(size: 8.5))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                if info.isProjected {
                                    Text("(\(L10n.text("Projected")))")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .position(
                                x: min(max(info.point.x, 60), width - 60),
                                y: max(verticalInset + 10, info.point.y - 18)
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            isHovering = true
                            hoverLocation = location
                        case .ended:
                            isHovering = false
                            hoverLocation = nil
                        }
                    }
                    .onAppear {
                        guard isLive, !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
                    }
                }
                .frame(height: 64)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

                HStack(alignment: .top) {
                    curveCaption(title: L10n.text("Start"), pct: startSample.batteryPercentage, date: startSample.timestamp)
                    Spacer()
                    if curveMode == .power && peakWatts > 0 {
                        VStack(alignment: .center, spacing: 1) {
                            Text(L10n.text("PEAK POWER"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(Format.kilowatts(watts: peakWatts))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    curveCaption(
                        title: isLive ? L10n.text("Now") : L10n.text("Finished"),
                        pct: lastSample.batteryPercentage,
                        date: lastSample.timestamp,
                        emphasized: isLive,
                        isLive: isLive
                    )
                    if curveMode != .power, let effectiveTargetPct {
                        Spacer()
                        curveCaption(
                            title: isLive ? L10n.text("Ready") : L10n.text("Target"),
                            pct: effectiveTargetPct,
                            date: isLive ? readyDate : nil,
                            isProjected: isLive
                        )
                    }
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        )
    }

    @ViewBuilder
    private func curveCaption(
        title: String,
        pct: Double,
        date: Date?,
        emphasized: Bool = false,
        isLive: Bool = false,
        isProjected: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if isLive {
                    Circle()
                        .fill(HisingenTheme.accent)
                        .frame(width: 4, height: 4)
                }
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
            }
            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 12, weight: emphasized ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? HisingenTheme.accent : .primary)
            if let date {
                Text(Format.shortTime(date: date))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func smoothPath(_ points: [CGPoint]) -> Path {
        ChargingCharts.smoothPath(points)
    }
}

struct MiniSparklineView: View {
    let samples: [ChargingSample]

    var body: some View {
        guard samples.count >= 2 else { return AnyView(EmptyView()) }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let pcts = ordered.map(\.batteryPercentage)
        let minV = pcts.min() ?? 0
        let maxV = pcts.max() ?? 100
        let span = max(1.0, maxV - minV)
        let firstDate = ordered.first?.timestamp ?? Date()
        let duration = max(1, (ordered.last?.timestamp ?? firstDate).timeIntervalSince(firstDate))

        return AnyView(
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let pointSegments = ChargingCharts.contiguousSegments(ordered).map { segment in
                    segment.map { sample -> CGPoint in
                        let x = CGFloat(sample.timestamp.timeIntervalSince(firstDate) / duration) * w
                        let y = (1.0 - CGFloat((sample.batteryPercentage - minV) / span)) * (h - 4) + 2
                        return CGPoint(x: x, y: y)
                    }
                }
                let points = pointSegments.flatMap { $0 }

                ZStack {
                    ForEach(pointSegments.indices, id: \.self) { index in
                        let segment = pointSegments[index]
                        if segment.count >= 2, let first = segment.first, let last = segment.last {
                            ChargingCharts.stepPath(segment)
                                .addingClosedBottom(firstX: first.x, lastX: last.x, bottomY: h)
                                .fill(
                                    LinearGradient(
                                        colors: [HisingenTheme.accent.opacity(0.35), HisingenTheme.accent.opacity(0.02)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                            ChargingCharts.stepPath(segment)
                                .stroke(HisingenTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                    }

                    if let last = points.last {
                        Circle()
                            .fill(HisingenTheme.accent)
                            .frame(width: 3.5, height: 3.5)
                            .position(last)
                    }
                }
            }
            .frame(width: 44, height: 16)
        )
    }


}

private extension Path {
    func addingClosedBottom(firstX: CGFloat, lastX: CGFloat, bottomY: CGFloat) -> Path {
        var closed = self
        closed.addLine(to: CGPoint(x: lastX, y: bottomY))
        closed.addLine(to: CGPoint(x: firstX, y: bottomY))
        closed.closeSubpath()
        return closed
    }
}

/// Chart geometry shared by `ChargingCurveView` and `MiniSparklineView`.
enum ChargingCharts {
    static let maximumConnectedGap = HistoryInsights.chargingCurveGapThreshold

    struct SampleGap: Equatable, Sendable {
        let startedAt: Date
        let endedAt: Date
    }

    /// Splits observations before rendering so the UI never invents a continuous line across
    /// a period that was too sparse to support energy integration.
    static func contiguousSegments(
        _ samples: [ChargingSample], maximumGap: TimeInterval = maximumConnectedGap
    ) -> [[ChargingSample]] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return [] }
        var result: [[ChargingSample]] = []
        var current = [first]
        for sample in ordered.dropFirst() {
            if sample.timestamp.timeIntervalSince(current[current.count - 1].timestamp) > maximumGap {
                result.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        result.append(current)
        return result
    }

    static func gaps(
        in samples: [ChargingSample], maximumGap: TimeInterval = maximumConnectedGap
    ) -> [SampleGap] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        return zip(ordered, ordered.dropFirst()).compactMap { first, second in
            guard second.timestamp.timeIntervalSince(first.timestamp) > maximumGap else { return nil }
            return SampleGap(startedAt: first.timestamp, endedAt: second.timestamp)
        }
    }

    /// SoC is reported in rounded steps, so a step path is more truthful than a spline that
    /// can overshoot between observations and visually invent charge or discharge events.
    static func stepPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        var previous = first
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: previous.y))
            path.addLine(to: point)
            previous = point
        }
        return path
    }

    /// Catmull-Rom → cubic Bézier smoothing over the given points.
    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 0..<points.count - 1 {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }
}
