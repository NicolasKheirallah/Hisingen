import Foundation
import NIOCore
import NIOPosix
import Sparkle
import Testing
@testable import Hisingen

/// The update feed path end to end, with no internet: a loopback HTTP server serves one
/// fixture appcast, the real Sparkle updater fetches and parses it against a throwaway host
/// bundle, and the app's own `UpdateService` receives the delegate callbacks. The two cases
/// that matter are a newer version (the state the menu-bar badge depends on) and a malformed
/// feed (which must surface as a failure, never as "you're up to date").
///
/// The host bundle is a temporary `.app` directory with an Info.plist, so Sparkle compares
/// against version 1 rather than this test binary. A fresh Ed25519 public key is generated
/// per run; feed signing is off because the fixture feed is unsigned and never trusted.
@Suite("SparkleFeed", .serialized)
@MainActor
struct SparkleFeedTests {

    @Test(.timeLimit(.minutes(2)))
    func aNewerFixtureAppcastReachesTheAppsAvailableUpdateState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FixtureAppcastServer(appcast: try fixtureAppcast("appcast-newer"))
        let feedURL = "http://127.0.0.1:\(try server.start())/appcast.xml"
        defer { server.stop() }

        let host = try fixtureHostBundle(feedURL: feedURL, in: directory)
        let service = UpdateService()
        let driver = NoopUserDriver()
        let updater = SPUUpdater(
            hostBundle: host, applicationBundle: host, userDriver: driver, delegate: service)

        try updater.start()
        updater.automaticallyChecksForUpdates = false
        updater.checkForUpdateInformation()

        await waitUntil { service.state != .idle }

        #expect(server.requestCount == 1, "the updater asked the fixture feed \(server.requestCount) times")
        let expected = UpdateService.State.updateAvailable(
            .init(marketingVersion: "999.0.0", build: "999"))
        #expect(service.state == expected, """
            A newer fixture appcast did not reach the app's available-update state; got \
            \(service.state) from \(server.requestCount) feed request(s).
            """)
    }

    @Test(.timeLimit(.minutes(2)))
    func aMalformedFixtureAppcastAbortsInsteadOfReportingNoUpdate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FixtureAppcastServer(appcast: try fixtureAppcast("appcast-malformed"))
        let feedURL = "http://127.0.0.1:\(try server.start())/appcast.xml"
        defer { server.stop() }

        let host = try fixtureHostBundle(feedURL: feedURL, in: directory)
        let probe = FeedOutcomeProbe(feedURL: feedURL)
        let updater = SPUUpdater(
            hostBundle: host, applicationBundle: host, userDriver: NoopUserDriver(), delegate: probe)

        try updater.start()
        updater.automaticallyChecksForUpdates = false
        updater.checkForUpdateInformation()

        await waitUntil { probe.abortError != nil || probe.finished }

        #expect(probe.foundItem == nil, "an unparseable feed must never produce an update item")
        #expect(probe.notFoundError == nil, """
            A malformed appcast was reported as "no update found"; a broken feed must not \
            reach the same callback as an up-to-date one.
            """)
        let error = try #require(probe.abortError, """
            A malformed appcast was accepted silently: Sparkle reported a finished cycle \
            without an abort error, so the app would show "up to date" for a broken feed.
            """)
        #expect(!error.localizedDescription.isEmpty, "the abort error must carry a readable reason")
        #expect(server.requestCount >= 1)

        // The app maps an aborted manual check to the retry state; the same error code path
        // runs for a real check initiated from the menu bar.
        let afterAbort = UpdateService.stateAfterAbortedCycle(.checking)
        guard case .failed(let message) = afterAbort else {
            Issue.record("an aborted check must leave the failed state, got \(afterAbort)")
            return
        }
        #expect(message == L10n.text("Update check failed. Please try again later."))
    }

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleFeedTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureAppcast(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "xml"),
            "\(name).xml is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// A throwaway `.app` Sparkle can treat as the host: version 1, an unsigned fixture feed,
    /// and a valid 32-byte Ed25519 public key so start-up validation passes without a signature.
    private func fixtureHostBundle(feedURL: String, in directory: URL) throws -> Bundle {
        let app = directory.appendingPathComponent("HisingenFeedFixture.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data().write(to: macOS.appendingPathComponent("HisingenFeedFixture"))
        let publicKey = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.kheirallah.hisingen.sparkle-feed-fixture",
            "CFBundleName": "HisingenFeedFixture",
            "CFBundleExecutable": "HisingenFeedFixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "SUFeedURL": feedURL,
            "SUPublicEDKey": publicKey,
            "SUEnableAutomaticChecks": true,
            "SUScheduledCheckInterval": 86_400,
            "SURequireSignedFeed": false,
            "SUVerifyUpdateBeforeExtraction": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: app), "could not load the fixture host bundle")
    }

    /// Polls on the main actor so Sparkle's callbacks, dispatched to the main thread, can land.
    private func waitUntil(
        timeout: Duration = .seconds(90), _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - Delegate probe

/// Records the callbacks that distinguish "a broken feed" from "no newer version": Sparkle
/// calls `updaterDidNotFindUpdate(_:error:)` for the latter (with `SUNoUpdateError`) and
/// `updater(_:didAbortWithError:)` only for a non-recoverable failure such as an unparseable
/// feed. They are kept apart so a valid, older feed cannot satisfy the malformed-feed test.
@MainActor
private final class FeedOutcomeProbe: NSObject, SPUUpdaterDelegate {
    let feedURL: String
    private(set) var foundItem: SUAppcastItem?
    private(set) var abortError: (any Error)?
    private(set) var notFoundError: (any Error)?
    private(set) var finished = false

    init(feedURL: String) { self.feedURL = feedURL }

    func feedURLString(for updater: SPUUpdater) -> String? { feedURL }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundItem = item
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        abortError = error
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        notFoundError = error
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        finished = true
    }
}

// MARK: - Loopback feed

private enum FixtureServerError: Error {
    case missingPort
}

/// Serves one appcast over plain HTTP on 127.0.0.1. Nothing leaves the machine, and the
/// fixture bytes are the same file the suite reads, so the test has no external dependency.
private final class FixtureAppcastServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private let body: Data
    private let lock = NSLock()
    private var requests = 0

    init(appcast: Data) { body = appcast }

    var requestCount: Int { lock.withLock { requests } }

    func recordRequest() { lock.withLock { requests += 1 } }

    func start() throws -> Int {
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Handler(server: self)).map { _ in () }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        self.channel = channel
        guard let port = channel.localAddress?.port else {
            throw FixtureServerError.missingPort
        }
        return port
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
        channel = nil
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private let server: FixtureAppcastServer
        private var responded = false
        private var received = ByteBuffer()

        init(server: FixtureAppcastServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = unwrapInboundIn(data)
            if let bytes = incoming.readBytes(length: incoming.readableBytes) {
                received.writeBytes(bytes)
            }
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            guard !responded else { return }
            let requestLine = received.getString(at: 0, length: min(received.readableBytes, 256)) ?? ""
            guard requestLine.contains("GET ") else { return }
            responded = true
            server.recordRequest()

            let body = server.body
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/rss+xml; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "Connection: close\r\n\r\n"
            var outbound = context.channel.allocator.buffer(capacity: head.utf8.count + body.count)
            outbound.writeString(head)
            outbound.writeBytes(body)
            context.writeAndFlush(wrapOutboundOut(outbound), promise: nil)
            context.close(promise: nil)
        }
    }
}

// MARK: - User driver

/// Sparkle demands a user driver even for a probing check that never shows UI. Every reply
/// is the least intrusive option, so an unexpected callback cannot open a window or block.
@MainActor
private final class NoopUserDriver: NSObject, SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        reply(.dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error) async {}

    func showUpdaterError(_ error: any Error) async {}

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.dismiss)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}

    func dismissUpdateInstallation() {}

    func showUpdateInFocus() {}
}
