// swift-tools-version:5.9
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
        .macOS(.v14)
    ],
    dependencies: [
        // Sparkle supplies the hardened, signature-verifying installer rather than
        // treating a GitHub release asset as executable input in application code.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Hisingen",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Hisingen",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "HisingenTests",
            dependencies: ["Hisingen"],
            path: "Tests/HisingenTests",
            resources: [.process("Fixtures")],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
