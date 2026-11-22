import Foundation
import Testing
@testable import Hisingen

/// The accessibility pass: the chart rotor has numbers to read, the controls that step values
/// are adjustable without a pointer, the keyboard stops follow the visual order, and motion in
/// charts answers Reduce Motion.
///
/// SwiftUI has no test host here, so the surface-level invariants are checked in source. Each
/// check names the view it guards, and the behavioural half (how a gesture moves a value) is
/// tested directly on `LimitStepping`.
struct AccessibilityPassTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Unit/
            .deletingLastPathComponent()   // HisingenTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Comments discuss these modifiers, so a comment must not satisfy a count.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func uiSources() throws -> [(path: String, text: String)] {
        let root = packageRoot.appendingPathComponent("Sources/Hisingen/UI")
        return try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { relative in
                (relative, try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
            }
    }

    // MARK: - Charts

    @Test func everyChartCarriesRotorData() throws {
        var chartTotal = 0
        var descriptorTotal = 0
        var chartFiles: [String] = []

        for file in try Self.uiSources() {
            let code = Self.codeOnly(file.text)
            let charts = Self.chartCount(in: code)
            guard charts > 0 else { continue }
            chartFiles.append(file.path)
            chartTotal += charts

            let descriptors = code.components(separatedBy: ".accessibilityChartDescriptor(").count - 1
            descriptorTotal += descriptors

            // The generic scrub wrapper in HistoryChartSupport is one `Chart` whose descriptor,
            // label and value come from the view that composes it; every other chart file has to
            // cover its own charts.
            if file.path != "History/HistoryChartSupport.swift" {
                #expect(
                    descriptors >= charts,
                    "\(file.path) has \(charts) chart(s) but \(descriptors) chart descriptor(s); a VoiceOver user would hear its summary but not its points."
                )
                // Every chart file speaks a label and a value as well, so the rotor and the
                // element description agree with each other.
                #expect(code.contains(".accessibilityLabel("), "\(file.path) has no accessibility label")
                #expect(code.contains(".accessibilityValue("), "\(file.path) has no accessibility value")
            }
        }

        #expect(chartFiles.count >= 10, "guardrail found only \(chartFiles.count) chart files; path resolution broke")
        #expect(
            descriptorTotal >= chartTotal,
            "\(chartTotal) charts across the UI carry \(descriptorTotal) descriptors; every chart needs rotor data or an explicit caller."
        )
    }

    @Test func theScrubWrapperTakesItsAccessibilityFromTheCaller() throws {
        // The one chart that intentionally has no descriptor of its own. If its callers stop
        // attaching one, the exemption above would hide a regression, so the exemption is
        // pinned here together with the call sites that do the work.
        let wrapper = try Self.source("Sources/Hisingen/UI/History/HistoryChartSupport.swift")
        #expect(Self.codeOnly(wrapper).contains("struct HistoryScrubChart"))

        let callers = try Self.uiSources()
            .filter { $0.path != "History/HistoryChartSupport.swift" }
            .filter { Self.codeOnly($0.text).contains("HistoryScrubChart(") }
        #expect(!callers.isEmpty, "HistoryScrubChart has no callers")
        for caller in callers {
            #expect(
                Self.codeOnly(caller.text).contains(".accessibilityChartDescriptor("),
                "\(caller.path) composes HistoryScrubChart without a chart descriptor"
            )
        }
    }

    // MARK: - Adjustable controls

    @Test func theLimitCardsAreAdjustableWithoutAPointer() throws {
        let instrument = try Self.source("Sources/Hisingen/UI/Vehicle/NowInstrument.swift")
        let code = Self.codeOnly(instrument)

        // The card's single button only climbs. VoiceOver's adjust gesture gets both directions.
        #expect(code.contains(".accessibilityAdjustableActionIf("))
        #expect(code.contains("LimitStepping.adjusted("))
        #expect(code.contains("direction: limitDirection"))
    }

    @Test func existingAdjustableSurfacesKeepTheirGesture() throws {
        // Heating steppers and the live charging curve already had the gesture; the pass must
        // not remove either while adding the limit cards.
        #expect(try Self.source("Sources/Hisingen/UI/Components/HeatingControls.swift")
            .contains(".accessibilityAdjustableAction"))
        #expect(try Self.source("Sources/Hisingen/UI/History/ChargingChartsViews.swift")
            .contains(".accessibilityAdjustableAction"))
    }

    // MARK: - Focus order

    @Test func thePopoverFocusSectionsFollowItsVisualOrder() throws {
        let source = try Self.source("Sources/Hisingen/UI/Shell/HisingenContentView.swift")
        let code = Self.codeOnly(source)

        #expect(code.components(separatedBy: ".focusSection()").count - 1 == 3,
                "expected three focus sections: the tab bar, the tab content and the footer")

        // The body stacks the three regions in this order; the focus sections are attached to
        // those same declarations, so Tab moves down the panel rather than around it.
        let body = try #require(code.range(of: "var body: some View"))
        let bodyText = String(code[body.lowerBound...])
        let tabBar = try #require(bodyText.range(of: "tabBar"))
        let content = try #require(bodyText.range(of: "selectedTabContent"))
        let footer = try #require(bodyText.range(of: "footerBar"))
        #expect(tabBar.lowerBound < content.lowerBound)
        #expect(content.lowerBound < footer.lowerBound)

        #expect(Self.function("panelHeader", in: source).contains(".focusSection()"),
                "the tab bar is not a focus section")
        #expect(Self.declaration("footerBar", in: source).contains(".focusSection()"),
                "the footer is not a focus section")
    }

    @Test func theSettingsFocusSectionsFollowItsVisualOrder() throws {
        let source = try Self.source("Sources/Hisingen/UI/Settings/SettingsView.swift")
        let code = Self.codeOnly(source)

        // Header, sidebar (or the compact navigation bar), then the destination column.
        #expect(code.components(separatedBy: ".focusSection()").count - 1 == 4)
        #expect(Self.declaration("headerBar", in: source).contains(".focusSection()"))
        #expect(Self.declaration("settingsContent", in: source).contains(".focusSection()"))

        let body = try #require(code.range(of: "var body: some View"))
        let bodyText = String(code[body.lowerBound...])
        let sidebar = try #require(bodyText.range(of: "SettingsSidebar("))
        let content = try #require(bodyText.range(of: "settingsContent"))
        #expect(sidebar.lowerBound < content.lowerBound,
                "the sidebar must come before the content column for Tab order to match the screen")
    }

    @Test func theSettingsSidebarOrderIsTheFocusOrder() throws {
        // The sidebar lists `SettingsSection.allCases` as they are declared; that order is the
        // focus order, so a reordering is a visible accessibility change, not a cosmetic one.
        #expect(SettingsSection.allCases.map(\.rawValue) == [
            "all", "accounts", "appearance", "tabsAndCards", "general",
            "electricity", "features", "notifications", "privacyData", "updates"
        ])
    }

    @Test func destinationFocusOrderStaysGroupedBySection() {
        // Focus walks the destination column top to bottom. If destinations for a sidebar section
        // were interleaved, Tab would jump between groups while the sidebar highlight stayed put.
        var seen = Set<SettingsSection>()
        var previous: SettingsSection?
        for destination in SettingsDestination.allCases {
            let section = destination.section
            if section != previous {
                #expect(!seen.contains(section), "\(destination) reopens the \(section.rawValue) group after another section")
                if let previous { seen.insert(previous) }
                previous = section
            }
        }
    }

    // MARK: - Reduce Motion

    @Test func chartMotionAnswersReduceMotion() throws {
        let chartFiles = try Self.uiSources()
            .filter { $0.path.hasPrefix("History/") || $0.path == "Vehicle/PriceCurveView.swift" || $0.path == "Info/InfoTabView+Diagnostics.swift" }

        for file in chartFiles {
            for line in Self.codeOnly(file.text).split(separator: "\n") {
                guard line.contains("withAnimation(") || line.contains(".animation(") else { continue }
                #expect(
                    line.contains("Motion.resolve") || line.contains("reduceMotion ?"),
                    "\(file.path) animates without asking Reduce Motion: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
    }

    @Test func thePanelKeepsItsReduceMotionBranches() throws {
        // The panel's own transitions resolve at the call site; the pass must not replace them
        // with raw curves. `Motion.resolve` and the `reduceMotion ?` branches are the two
        // sanctioned forms, the same ones `MotionSystemTests` proves resolve to nil or a
        // cross-fade.
        let shell = Self.codeOnly(try Self.source("Sources/Hisingen/UI/Shell/HisingenContentView.swift"))
        #expect(shell.contains("reduceMotion ? nil : Motion.interaction"))
        #expect(shell.contains("reduceMotion ? .opacity"))
    }

    // MARK: - Helpers

    private static func chartCount(in code: String) -> Int {
        let pattern = try? NSRegularExpression(pattern: #"\bChart\s*[\\({]"#)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return pattern?.numberOfMatches(in: code, range: range) ?? 0
    }

    /// The source of one function declaration, up to the next top-level declaration.
    private static func function(_ name: String, in source: String) -> String {
        let marker = "func \(name)("
        guard let start = source.range(of: marker) else { return "" }
        let rest = source[start.lowerBound...]
        let terminators = ["\n    private var ", "\n    var ", "\n    private func ", "\n    func "]
        let end = terminators
            .compactMap { rest.range(of: $0, range: rest.index(after: rest.startIndex)..<rest.endIndex)?.lowerBound }
            .min() ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The source of one stored property or computed property declaration, up to the next
    /// top-level `private`/`var`/`func` declaration. Good enough to tell which modifiers belong
    /// to `panelHeader`, `footerBar`, `headerBar` or `settingsContent`.
    private static func declaration(_ name: String, in source: String) -> String {
        let marker = "var \(name): some View"
        guard let start = source.range(of: marker) else { return "" }
        let rest = source[start.lowerBound...]
        let terminators = ["\n    private var ", "\n    var ", "\n    private func ", "\n    func "]
        let end = terminators
            .compactMap { rest.range(of: $0, range: rest.index(after: rest.startIndex)..<rest.endIndex)?.lowerBound }
            .min() ?? rest.endIndex
        return String(rest[..<end])
    }
}
