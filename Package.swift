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

/// Complete concurrency checking is enforced for every build path — `swift build`, Xcode,
/// IDE indexing, `make run` — rather than only when the CI/Makefile pass the CLI flag.
/// The Swift 6 language mode itself is set per target below.
private let concurrencySwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

private let testSwiftSettings: [SwiftSetting] = concurrencySwiftSettings + (usesStandaloneCommandLineTools
    ? [.unsafeFlags(["-F", testingFrameworks])]
    : [])
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
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        // Keep the transitive graph usable by Swift 6.0.
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
        .package(url: "https://github.com/apple/swift-http-structured-headers.git", exact: "1.7.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.1.7"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", exact: "1.35.2"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5"),
        .package(url: "https://github.com/apple/swift-numerics.git", exact: "1.1.1"),
        .package(url: "https://github.com/apple/swift-algorithms.git", exact: "1.2.1"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.46.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Hisingen",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport")
            ],
            path: "Sources/Hisingen",
            exclude: ["Resources"],
            swiftSettings: concurrencySwiftSettings
        ),
        .testTarget(
            name: "HisingenTests",
            dependencies: ["Hisingen",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2")],
            path: "Tests/HisingenTests",
            resources: [.process("Fixtures")],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
