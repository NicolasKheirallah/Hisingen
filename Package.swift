// swift-tools-version:6.0
import PackageDescription
import Foundation

private let commandLineTools = "/Library/Developer/CommandLineTools"

/// Standalone Command Line Tools ships Swift Testing outside the SDK. SwiftPM
/// finds this automatically in full Xcode, but needs the matching framework and
/// interoperability-library search paths when CLT is the selected toolchain.
private func selectedDeveloperDirectory() -> String? {
    if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
        return override
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = output
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private let usesStandaloneCommandLineTools = selectedDeveloperDirectory() == commandLineTools
private let testingFrameworks = "\(commandLineTools)/Library/Developer/Frameworks"
private let testingLibraries = "\(commandLineTools)/Library/Developer/usr/lib"

private let testSwiftSettings: [SwiftSetting] = usesStandaloneCommandLineTools
    ? [.unsafeFlags(["-F", testingFrameworks])]
    : []
private let testLinkerSettings: [LinkerSetting] = usesStandaloneCommandLineTools
    ? [.unsafeFlags([
        "-F\(testingFrameworks)",
        "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", testingLibraries
    ])]
    : []

let package = Package(
    name: "Hisingen",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Sparkle supplies the hardened, signature-verifying installer rather than
        // treating a GitHub release asset as executable input in application code.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.13.1"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.1.7"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.17.2"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.6"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.46.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.6"),
    ],
    targets: [
        // Shared with the widget extension: the widget-facing AppIntent types and the seam the
        // app registers at launch. An extension cannot link the app executable, so the types
        // and the dispatch protocol must live in a module both targets can depend on.
        .target(
            name: "HisingenIntents",
            path: "Sources/HisingenIntents"
        ),
        .executableTarget(
            name: "Hisingen",
            dependencies: [
                "HisingenIntents",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport")
            ],
            path: "Sources/Hisingen",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "HisingenTests",
            dependencies: [
                "Hisingen",
                // The widget and the app register the same intent types, so the suites that
                // exercise widget routing link the shared module.
                "HisingenIntents",
                // The per-car widget's selection resolver and garage reader live in the widget
                // target, so the fixture suites import it the same way HisingenWidgetTests
                // already imports both binaries. No new external products.
                "HisingenWidget",
                // `SparkleFeedTests` drives Sparkle's real updater against a loopback fixture
                // appcast. The app links Sparkle already; the suite needs the same module to
                // build a throwaway updater and read the parsed `SUAppcastItem`.
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2")],
            path: "Tests/HisingenTests",
            resources: [.process("Fixtures")],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .executableTarget(
            name: "HisingenWidget",
            // WidgetKit extension. The .appex bundle is hand-assembled by the Makefile the
            // same way the app is; SwiftPM only produces the binary here. It links the shared
            // intent module so the widget and the app register the same intent types; the
            // extension's Metadata.appintents is assembled from that dependency by
            // Scripts/generate-widget-appintents-metadata.sh. The Edit-sheet car picker also uses
            // a `WidgetConfigurationIntent`, which resolves inside this extension process and so
            // needs no metadata of its own.
            dependencies: ["HisingenIntents"],
            path: "Sources/HisingenWidget"
        ),
        .testTarget(
            name: "HisingenWidgetTests",
            // Round-trip tests need both sides: the app's snapshot writer and the widget's
            // snapshot reader live in separate targets with no shared module between them,
            // so this suite imports both and pins the JSON they exchange.
            dependencies: ["HisingenWidget", "Hisingen", "HisingenIntents"],
            path: "Tests/HisingenWidgetTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
