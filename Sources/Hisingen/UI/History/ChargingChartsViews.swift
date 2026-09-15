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

    /// Sample-derived geometry that does not depend on the hover position – rebuilt when the
    /// samples, live wattage, target or chart size change, not on every mouse move.
    private struct CurveGeometry {
        var sortedSamples: [ChargingSample] = []
        var socPointSegments: [[CGPoint]] = []
        var powerPointSegments: [[CGPoint]] = []
        var observationGaps: [ChargingCharts.SampleGap] = []
    }

    @State private var geometry = CurveGeometry()

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
        geometry.observationGaps
    }

    private func xCoord(_ date: Date, horizontalInset: CGFloat, chartWidth: CGFloat, timeStart: Date, totalSpan: TimeInterval) -> CGFloat {
        let fraction = CGFloat(date.timeIntervalSince(timeStart) / totalSpan)
        return horizontalInset + min(max(fraction, 0), 1) * chartWidth
    }

    private func yCoord(_ pct: Double, verticalInset: CGFloat, chartHeight: CGFloat, domainLow: Double, domainHigh: Double) -> CGFloat {
        let fraction = CGFloat((pct - domainLow) / (domainHigh - domainLow))
        return verticalInset + (1.0 - min(max(fraction, 0), 1)) * chartHeight
    }

    /// Recomputes everything the curve needs except the hover marker, so per-mouse-move body
    /// evaluations never re-sort samples or rebuild point arrays.
    private func refreshGeometry(width: CGFloat, height: CGFloat) {
        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 7
        let chartWidth = max(1, width - horizontalInset * 2)
        let chartHeight = max(1, height - verticalInset * 2)
        let (domainLow, domainHigh) = socDomain
        let (pwrLow, pwrHigh) = powerDomain
        let (timeStart, _) = timeSpan
        let totalSpan = max(60, timeSpan.end.timeIntervalSince(timeStart))

        func point(_ sample: ChargingSample, value: Double, low: Double, high: Double) -> CGPoint {
            CGPoint(
                x: xCoord(sample.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                y: yCoord(value, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: low, domainHigh: high)
            )
        }

        let powerSamples = samples.enumerated().compactMap { index, sample -> ChargingSample? in
            let watts = sample.powerWatts ?? (index == samples.count - 1 ? currentPowerWatts : nil)
            guard let watts, watts > 0 else { return nil }
            return ChargingSample(
                timestamp: sample.timestamp, batteryPercentage: sample.batteryPercentage,
                powerWatts: watts, chargingType: sample.chargingType
            )
        }

        geometry = CurveGeometry(
            sortedSamples: samples.sorted { $0.timestamp < $1.timestamp },
            socPointSegments: ChargingCharts.contiguousSegments(samples).map {
                $0.map { point($0, value: $0.batteryPercentage, low: domainLow, high: domainHigh) }
            },
            powerPointSegments: ChargingCharts.contiguousSegments(powerSamples).map {
                $0.map { point($0, value: Double($0.powerWatts ?? 0) / 1000.0, low: pwrLow, high: pwrHigh) }
            },
            observationGaps: ChargingCharts.gaps(in: samples)
        )
    }

    /// Binary search over the cached chronological samples – O(log n) per hover move.
    private func nearestSample(to date: Date) -> ChargingSample? {
        let sorted = geometry.sortedSamples
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        if low > 0,
           abs(sorted[low - 1].timestamp.timeIntervalSince(date)) < abs(sorted[low].timestamp.timeIntervalSince(date)) {
            return sorted[low - 1]
        }
        return sorted[low]
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

    @ViewBuilder
    var body: some View {
        if samples.isEmpty {
            EmptyView()
        } else {
            let (domainLow, domainHigh) = socDomain
            let (pwrLow, pwrHigh) = powerDomain
            let (timeStart, timeEnd) = timeSpan
            let totalSpan = max(60, timeEnd.timeIntervalSince(timeStart))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Label(curveMode == .power ? L10n.text("Power Curve") : L10n.text("Charging Curve"), systemImage: curveMode == .power ? "waveform.path.ecg" : "chart.xyaxis.line")
                        .hisType(.label, weight: .medium)
                        .foregroundStyle(.secondary)
                    if isLive {
                        Circle()
                            .fill(HisingenTheme.semanticGood)
                            .frame(width: 5, height: 5)
                            .opacity(pulse ? 1.0 : 0.45)
                            .animation(Motion.resolve(Motion.livePulse), value: pulse)
                        Text(L10n.text("Live"))
                            .textCase(.uppercase)
                            .hisType(.nano, weight: .bold)
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
                        .hisType(.label, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(curveMode == .power ? Color.green : HisingenTheme.accent)
                        .hisTelemetryValue(summaryText, reduceMotion: reduceMotion)
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
                    .hisType(.nano, weight: .medium)
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

                    // Cached, hover-independent geometry – see refreshGeometry.
                    let socPointSegments = geometry.socPointSegments
                    let socPoints = socPointSegments.flatMap { $0 }

                    let powerPointSegments = geometry.powerPointSegments
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
                            let closest = nearestSample(to: hoveredDate) ?? lastSample
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

                        guideLayers(width: width, horizontalInset: horizontalInset, verticalInset: verticalInset,
                                    chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh,
                                    pwrLow: pwrLow, pwrHigh: pwrHigh)

                        if curveMode == .soc || curveMode == .dual {
                            Group {
                                socLayers(socPointSegments: socPointSegments, bottomY: bottomY,
                                          lastSocPoint: lastSocPoint, projectedEnd: projectedEnd)
                            }
                            .transition(.opacity)
                        }

                        if curveMode == .power || curveMode == .dual {
                            Group {
                                powerLayers(powerPointSegments: powerPointSegments, bottomY: bottomY)
                            }
                            .transition(.opacity)
                        }

                        endpointDots(firstSocPoint: firstSocPoint, lastSocPoint: lastSocPoint,
                                     lastPowerPoint: lastPowerPoint)

                        if let info = hoverInfo {
                            Group {
                                hoverLayer(info: info, verticalInset: verticalInset, bottomY: bottomY, width: width)
                            }
                            .transition(.opacity)
                            .hisAnimation(Motion.interaction, value: isHovering)
                        }
                    }
                    // A mode switch is a selection, and `resolve` returns nil under Reduce Motion,
                    // so this was a hard cut where the app's own rule is a crossfade. It also used
                    // the entrance curve, which is for things arriving, not for a control toggling.
                    .hisAnimation(Motion.selection, value: curveMode)
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
                    // Hover moves never touch these inputs, so the geometry cache rebuilds
                    // only when the underlying data or layout actually changes.
                    .onChange(of: samples, initial: true) { _, _ in refreshGeometry(width: width, height: height) }
                    .onChange(of: geo.size, initial: true) { _, _ in refreshGeometry(width: width, height: height) }
                    .onChange(of: currentPowerWatts) { _, _ in refreshGeometry(width: width, height: height) }
                    .onChange(of: effectiveTargetPct) { _, _ in refreshGeometry(width: width, height: height) }
                    .onChange(of: readyDate) { _, _ in refreshGeometry(width: width, height: height) }
                    .onAppear {
                        guard isLive, !reduceMotion else { return }
                        withAnimation(Motion.livePulse) { pulse = true }
                    }
                }
                .frame(height: 64)
                .padding(.vertical, 2)
                // Was hidden outright, even though `TimeSeriesAXDescriptor` exists in this very
                // file and is attached at six other sites: a VoiceOver reader was told nothing
                // about the one view the card is built around.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Charging curve"))
                .accessibilityValue(chartAccessibilityValue(points: samples.map(\.batteryPercentage)))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Charging curve"),
                    yLabel: "%",
                    points: samples.map { ($0.timestamp, $0.batteryPercentage) }
                ))

                HStack(alignment: .top) {
                    curveCaption(title: L10n.text("Start"), pct: startSample.batteryPercentage, date: startSample.timestamp)
                    Spacer()
                    if curveMode == .power && peakWatts > 0 {
                        VStack(alignment: .center, spacing: 1) {
                            Text(L10n.text("PEAK POWER"))
                                .hisType(.nano, weight: .semibold)
                                .foregroundStyle(.tertiary)
                            Text(Format.kilowatts(watts: peakWatts))
                                .hisType(.label, weight: .bold)
                                .foregroundStyle(.green)
                                .hisTelemetryValue(peakWatts, reduceMotion: reduceMotion)
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
                            date: isLive ? readyDate : nil
                        )
                    }
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func curveCaption(
        title: String,
        pct: Double,
        date: Date?,
        emphasized: Bool = false,
        isLive: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if isLive {
                    Circle()
                        .fill(HisingenTheme.accent)
                        .frame(width: 4, height: 4)
                }
                Text(title)
                    .textCase(.uppercase)
                    .hisType(.nano, weight: .semibold)
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
            }
            Text(String(format: "%.0f%%", pct))
                .hisType(.body, weight: emphasized ? .bold : .semibold)
                .monospacedDigit()
                .foregroundStyle(emphasized ? HisingenTheme.accent : .primary)
                .hisTelemetryValue(pct, reduceMotion: reduceMotion)
            if let date {
                Text(Format.shortTime(date: date))
                    .hisType(.micro)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func smoothPath(_ points: [CGPoint]) -> Path {
        ChargingCharts.smoothPath(points)
    }

    // The chart layers below are extracted methods: keeping them inline made the chart
    // body exceed the type-checker's expression-size limit.

    /// Dashed target and average guide lines plus the target capsule; both fade when the
    /// mode switch makes them appear or disappear.
    @ViewBuilder
    private func guideLayers(width: CGFloat, horizontalInset: CGFloat, verticalInset: CGFloat,
                             chartHeight: CGFloat, domainLow: Double, domainHigh: Double,
                             pwrLow: Double, pwrHigh: Double) -> some View {
        if curveMode != .power, let effectiveTargetPct {
            Group {
                let guideY = yCoord(effectiveTargetPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                Path { path in
                    path.move(to: CGPoint(x: horizontalInset, y: guideY))
                    path.addLine(to: CGPoint(x: width - horizontalInset, y: guideY))
                }
                .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Text(L10n.format("Target %d%%", Int(effectiveTargetPct)))
                    .hisType(.nano, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(HisingenTheme.chipFill, in: Capsule())
                    .position(x: max(32, width - 36), y: max(verticalInset + 4, guideY - 9))
            }
            .transition(.opacity)
        }

        if (curveMode == .power || curveMode == .dual) && averageWatts > 0 {
            Group {
                let avgKw = Double(averageWatts) / 1000.0
                let avgY = yCoord(avgKw, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh)
                Path { path in
                    path.move(to: CGPoint(x: horizontalInset, y: avgY))
                    path.addLine(to: CGPoint(x: width - horizontalInset, y: avgY))
                }
                .stroke(Color.green.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            .transition(.opacity)
        }
    }

    /// Start / end point dots: the live ripple pair on SoC modes, a plain dot on power.
    @ViewBuilder
    private func endpointDots(firstSocPoint: CGPoint, lastSocPoint: CGPoint, lastPowerPoint: CGPoint) -> some View {
        if curveMode != .power {
            Group {
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
            }
            .transition(.opacity)
        } else {
            Circle()
                .fill(Color.green)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                .frame(width: 7.5, height: 7.5)
                .position(lastPowerPoint)
                .transition(.opacity)
        }
    }

    /// SoC fill, projection and stroke layers (`soc` / `dual` modes).
    @ViewBuilder
    private func socLayers(socPointSegments: [[CGPoint]], bottomY: CGFloat,
                           lastSocPoint: CGPoint, projectedEnd: CGPoint?) -> some View {
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

    /// Power fill and stroke layers (`power` / `dual` modes).
    @ViewBuilder
    private func powerLayers(powerPointSegments: [[CGPoint]], bottomY: CGFloat) -> some View {
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

    /// Hover rule line, marker and readout capsule. This is a pointer-tracking interaction, so all
    /// three move unanimated and therefore as one rigid group: the rule and the capsule always
    /// tracked the cursor directly, and easing only the marker made it slide along its own rule
    /// during a horizontal scrub, which is the opposite of what the old comment described.
    @ViewBuilder
    private func hoverLayer(info: (point: CGPoint, pct: Double, date: Date, powerWatts: Int?, isProjected: Bool),
                            verticalInset: CGFloat, bottomY: CGFloat, width: CGFloat) -> some View {
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
                .hisType(.micro, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.accent)
            if let watts = info.powerWatts, watts > 0 {
                Text("· \(Format.kilowatts(watts: watts))")
                    .hisType(.nano, weight: .semibold)
                    .foregroundStyle(.green)
            }
            Text("· " + Format.shortTime(date: info.date))
                .hisType(.nano)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if info.isProjected {
                Text("(\(L10n.text("Projected")))")
                    .hisType(.nano, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(HisingenTheme.chipFill, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .position(
            x: min(max(info.point.x, 60), width - 60),
            y: max(verticalInset + 10, info.point.y - 18)
        )
    }
}

struct MiniSparklineView: View {
    /// The charge shape had no text alternative and was not hidden either, so whether VoiceOver
    /// said anything about it was left to the shapes it happens to be drawn from.
    let samples: [ChargingSample]

    @ViewBuilder
    var body: some View {
        if samples.count < 2 {
            EmptyView()
        } else {
            let ordered = samples.sorted { $0.timestamp < $1.timestamp }
            let pcts = ordered.map(\.batteryPercentage)
            let minV = pcts.min() ?? 0
            let maxV = pcts.max() ?? 100
            let span = max(1.0, maxV - minV)
            let firstDate = ordered.first?.timestamp ?? Date()
            let duration = max(1, (ordered.last?.timestamp ?? firstDate).timeIntervalSince(firstDate))

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
            // The charge shape was neither labelled nor hidden, so whether VoiceOver said anything
            // depended on the shapes it is drawn from. It says the shape in words, which is the
            // only thing a 44x16 line can carry.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Charge shape"))
            .accessibilityValue(chartAccessibilityValue(points: pcts))
        }
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
    /// a period that was too sparse to support energy integration. Delegates to
    /// `HistoryInsights.segments` so the gap rule lives in exactly one place.
    static func contiguousSegments(
        _ samples: [ChargingSample], maximumGap: TimeInterval = maximumConnectedGap
    ) -> [[ChargingSample]] {
        // `HistoryInsights.segments` expects chronologically-sorted input.
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        return HistoryInsights.segments(of: ordered, maxGap: maximumGap, timestamp: \.timestamp)
    }

    /// Gaps are exactly the boundaries between consecutive runs, derived from the same
    /// segmentation instead of a parallel threshold comparison.
    static func gaps(
        in samples: [ChargingSample], maximumGap: TimeInterval = maximumConnectedGap
    ) -> [SampleGap] {
        let segments = contiguousSegments(samples, maximumGap: maximumGap)
        guard segments.count > 1 else { return [] }
        return zip(segments, segments.dropFirst()).compactMap { run, next in
            guard let last = run.last, let first = next.first else { return nil }
            return SampleGap(startedAt: last.timestamp, endedAt: first.timestamp)
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
