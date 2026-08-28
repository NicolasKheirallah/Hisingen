import AppKit
import Foundation
import OSLog
import Sparkle

/// The small application-facing boundary around Sparkle. Sparkle owns appcast parsing,
/// download progress, Ed25519 verification, safe replacement, permission prompts and
/// relaunching; vehicle services never need to know how Hisingen updates itself.
@MainActor
final class UpdateService: NSObject, SPUUpdaterDelegate {
    private static let updateCheckFailureMessage = "Update check failed. Please try again later."

    struct AvailableUpdate: Equatable {
        let marketingVersion: String
        let build: String
    }

    enum State: Equatable {
        case idle
        case checking
        case updateAvailable(AvailableUpdate)
        case failed(String)
    }

    private static let logger = AppLog.logger("updates")
    private var didStart = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    var onStateChanged: ((State) -> Void)?

    private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    var isReady: Bool {
        didStart && controller.updater.canCheckForUpdates
    }

    /// Starts only from a real app bundle with a real public key. This deliberately fails
    /// closed for developer builds and incomplete release configuration instead of making
    /// an unauthenticated request to GitHub.
    func start(automaticallyChecks: Bool, automaticallyDownloads: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Self.logger.debug("Updater unavailable outside an app bundle")
            return
        }
        guard Self.hasConfiguredPublicKey(Bundle.main) else {
            Self.logger.error("Updater disabled because the embedded Ed25519 public key is missing")
            state = .failed("This build is not configured for secure updates.")
            return
        }

        let updater = controller.updater
        if !didStart {
            do {
                try updater.start()
                // Old Sparkle integrations could persist a feed URL in defaults. Hisingen
                // never supports that override: the signed, bundled HTTPS feed is canonical.
                _ = updater.clearFeedURLFromUserDefaults()
                didStart = true
                Self.logger.info("Updater started; current version \(Self.currentVersionDescription(), privacy: .public)")
            } catch {
                fail("Unable to start the secure updater", error: error)
                return
            }
        }
        updater.automaticallyChecksForUpdates = automaticallyChecks
        updater.automaticallyDownloadsUpdates = automaticallyDownloads
        Self.logger.info("Automatic update checks \(automaticallyChecks ? "enabled" : "disabled", privacy: .public); automatic downloads \(automaticallyDownloads ? "enabled" : "disabled", privacy: .public)")
    }

    func checkForUpdates() {
        guard didStart else {
            state = .failed("Secure updates are unavailable in this build.")
            return
        }
        guard controller.updater.canCheckForUpdates else {
            // Sparkle brings any existing native update/progress window to the foreground.
            controller.updater.checkForUpdates()
            return
        }
        Self.logger.info("User initiated update check; current version \(Self.currentVersionDescription(), privacy: .public)")
        state = .checking
        controller.updater.checkForUpdates()
    }

    func configure(automaticallyChecks: Bool, automaticallyDownloads: Bool) {
        guard didStart else { return }
        controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads
        Self.logger.info("Update preferences changed")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = AvailableUpdate(marketingVersion: item.displayVersionString, build: item.versionString)
        Self.logger.info("Update found: version \(update.marketingVersion, privacy: .public) build \(update.build, privacy: .public), size \(item.contentLength, privacy: .public) bytes")
        state = .updateAvailable(update)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let nsError = error as NSError
        // Sparkle uses this callback for both the ordinary up-to-date case and cases it
        // rejects (for example an update that requires a newer macOS). Its standard driver
        // presents a user-initiated error; preserve the technical reason in unified logging
        // while returning the menu bar to its neutral state.
        Self.logger.info("No eligible update found: \(nsError.localizedDescription, privacy: .public)")
        state = .idle
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Self.logger.info("Update download completed: \(item.displayVersionString, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        fail("Update download failed for \(item.displayVersionString)", error: error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nextState = Self.stateAfterAbortedCycle(state)
        guard nextState != state else { return }
        let reason = (error as NSError).localizedDescription
        Self.logger.error("Update check aborted: \(reason, privacy: .public)")
        state = nextState
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        // Sparkle reaches extraction only after the appcast/enclosure signatures pass when
        // SURequireSignedFeed and SUVerifyUpdateBeforeExtraction are enabled.
        Self.logger.info("Update signature verification passed for \(item.displayVersionString, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.logger.info("Installation started for \(item.displayVersionString, privacy: .public)")
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Self.logger.info("Installation completed; requesting relaunch")
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Stable is Sparkle's default channel. Beta can be opt-in later without letting
        // prerelease appcast entries reach stable users.
        []
    }

    private func fail(_ operation: String, error: any Error) {
        let reason = (error as NSError).localizedDescription
        Self.logger.error("\(operation, privacy: .public): \(reason, privacy: .public)")
        state = .failed("\(operation). Please try again later.")
    }

    static func hasConfiguredPublicKey(_ bundle: Bundle) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              key != "__SPARKLE_PUBLIC_ED_KEY__",
              let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return true
    }

    static func currentVersionDescription(bundle: Bundle = .main) -> String {
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(marketing) (build \(build))"
    }

    /// Sparkle reports feed download, parsing, and signature failures through its abort
    /// callback. Only a manual check owns the `.checking` state; later states such as an
    /// available update or a download failure must not be overwritten by cycle cleanup.
    static func stateAfterAbortedCycle(_ current: State) -> State {
        guard current == .checking else { return current }
        return .failed(updateCheckFailureMessage)
    }
}

/// Sparkle compares CFBundleVersion during installation. Releases also carry the marketing
/// version for display; this type keeps release tooling/tests explicit about both values.
struct HisingenReleaseVersion: Comparable, Equatable {
    let marketing: [Int]
    let build: Int

    init?(marketingVersion: String, build: String) {
        let values = marketingVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, let parsedBuild = Int(build), parsedBuild >= 0 else { return nil }
        let parsedMarketing = values.compactMap { Int($0) }
        guard parsedMarketing.count == 3, parsedMarketing.allSatisfy({ $0 >= 0 }) else { return nil }
        marketing = parsedMarketing
        self.build = parsedBuild
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<3 where lhs.marketing[index] != rhs.marketing[index] {
            return lhs.marketing[index] < rhs.marketing[index]
        }
        return lhs.build < rhs.build
    }
}
