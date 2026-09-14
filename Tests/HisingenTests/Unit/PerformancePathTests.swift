import Foundation
import Testing
@testable import Hisingen

@Suite("Background and image performance paths", .serialized)
struct PerformancePathTests {
    @Test("Garage scans request only fleet-summary fields")
    func garageFeatureBudget() {
        #expect(FeatureSelection.garageScan.enabled == [
            .vehicleIdentity, .chargingDetails, .vehicleAvailability,
            .vehicleHealth, .exteriorStatus, .tyreAndWarnings
        ])
        #expect(!FeatureSelection.garageScan.contains(.vehicleImage))
        #expect(!FeatureSelection.garageScan.contains(.vehicleLocation))
        #expect(!FeatureSelection.garageScan.contains(.tripMeters))
    }

    @Test("Image writes use SQLite as the only durable tier")
    func singleDurableImageTier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HisingenImagePerformance-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = VehicleDatabase.inMemory()
        let cache = CarImageCache(cacheDirectory: directory, database: database)
        let bytes = Data([1, 2, 3, 4])

        cache.save(bytes, for: "image-vin", angle: 0)
        await cache.waitUntilIdle()
        cache.dropMemoryCache(for: "IMAGE-VIN")

        #expect(cache.image(for: "IMAGE-VIN", angle: 0) == bytes)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("IMAGE-VIN_angle0.jpg").path
        ))
    }

    @Test("Presentation equality never compares artwork bytes")
    func presentationFingerprintUsesArtworkIdentity() {
        var first = vehicle(vin: "IMAGE-VIN", imageData: Data(repeating: 1, count: 4))
        var samePresentation = first
        samePresentation.identity.imageData = Data(repeating: 2, count: 4)
        samePresentation.freshness.fetchedAt = first.freshness.fetchedAt.addingTimeInterval(10)
        #expect(VehiclePresentationFingerprint(first) == VehiclePresentationFingerprint(samePresentation))

        first.identity.imageData = Data(repeating: 1, count: 5)
        #expect(VehiclePresentationFingerprint(first) != VehiclePresentationFingerprint(samePresentation))
    }
}
