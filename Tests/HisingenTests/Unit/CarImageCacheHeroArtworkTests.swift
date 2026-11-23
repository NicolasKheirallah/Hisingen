import Foundation
import Testing
@testable import Hisingen

/// The Car tab reads its artwork as one bundle off the main thread, so `body` never queries
/// the image tier. These pin what that bundle contains.
struct CarImageCacheHeroArtworkTests {
    private let vin = "HERO_ARTWORK_VIN"

    private func bytes(_ count: Int) -> Data { Data(repeating: 0x7, count: count) }

    @Test
    func theBundleHoldsEveryStoredAngleAndTheInterior() async {
        let cache = CarImageCache(database: .inMemory())
        cache.save(bytes(10), for: vin, angle: 0)
        cache.save(bytes(20), for: vin, angle: 3)
        cache.saveInterior(bytes(30), for: vin)
        await cache.waitUntilIdle()

        let artwork = await cache.heroArtwork(for: vin)

        #expect(artwork.isLoaded)
        #expect(artwork.vin == vin)
        #expect(artwork.exterior.keys.sorted() == [0, 3])
        #expect(artwork.exterior[3]?.count == 20)
        #expect(artwork.interior?.count == 30)
    }

    @Test
    func aVehicleWithNoArtworkIsLoadedAndEmpty() async {
        let artwork = await CarImageCache(database: .inMemory()).heroArtwork(for: vin)

        #expect(artwork.isLoaded)
        #expect(artwork.exterior.isEmpty)
        #expect(artwork.interior == nil)
    }

    @Test
    func anotherVehiclesRendersAreNotIncluded() async {
        let cache = CarImageCache(database: .inMemory())
        cache.save(bytes(10), for: "OTHER_HERO_VIN", angle: 1)
        cache.saveInterior(bytes(10), for: "OTHER_HERO_VIN")
        await cache.waitUntilIdle()

        let artwork = await cache.heroArtwork(for: vin)

        #expect(artwork.exterior.isEmpty)
        #expect(artwork.interior == nil)
    }

    @Test
    func theBarePrimaryRenderIsNotAnAngle() async {
        let cache = CarImageCache(database: .inMemory())
        cache.save(bytes(10), for: vin)
        await cache.waitUntilIdle()

        #expect(await cache.heroArtwork(for: vin).exterior.isEmpty)
    }

    @Test
    func aRenderAnotherCacheInstanceSavedIsFound() async {
        let database = VehicleDatabase.inMemory()
        let reader = CarImageCache(database: database)
        #expect(await reader.heroArtwork(for: vin).exterior.isEmpty)

        let downloader = CarImageCache(database: database)
        downloader.save(bytes(10), for: vin, angle: 2)
        await downloader.waitUntilIdle()

        // The provider clients and the panel each own a cache over one database, so a miss must
        // never be remembered: a download the panel did not make still has to appear.
        #expect(await reader.heroArtwork(for: vin).exterior.keys.sorted() == [2])
    }

    @Test
    func equalityComparesByteCountsNotBytes() {
        var a = CarImageCache.HeroArtwork(vin: vin, exterior: [0: Data([1, 2])], isLoaded: true)
        var b = a
        b.exterior[0] = Data([9, 9])
        #expect(a == b)
        b.exterior[1] = Data([1])
        #expect(a != b)
        a.interior = Data([1])
        #expect(a != b)
    }
}

/// An erase has to be final. Writes are queued behind the caller, so a picture saved just before
/// a sign-out used to land in the database after the sign-out deleted that vehicle's rows.
struct CarImageCacheEraseTests {
    private let vin = "ERASE_RACE_VIN"
    private func bytes(_ seed: UInt8) -> Data { Data(repeating: seed, count: 64) }

    @Test
    func aWriteQueuedBeforeForgetDoesNotSurviveIt() async {
        let database = VehicleDatabase.inMemory()
        let cache = CarImageCache(database: database)
        // Enough queued writes that most are still waiting when the erase arrives.
        for angle in 0..<300 { cache.save(bytes(UInt8(angle % 200)), for: vin, angle: angle) }

        cache.forget(vin: vin)
        await cache.waitUntilIdle()

        #expect(database.images.vehicleImageAngles(for: vin).isEmpty,
                "A signed-out vehicle's pictures must not reappear in the database")
        #expect(cache.image(for: vin, angle: 7) == nil)
    }

    @Test
    func aWriteQueuedBeforeForgetAllDoesNotSurviveIt() async {
        let database = VehicleDatabase.inMemory()
        let cache = CarImageCache(database: database)
        for angle in 0..<300 { cache.save(bytes(UInt8(angle % 200)), for: vin, angle: angle) }

        cache.forgetAll()
        await cache.waitUntilIdle()

        #expect(database.images.vehicleImageAngles(for: vin).isEmpty)
    }

    @Test
    func aPictureSavedAfterForgetIsKept() async {
        let database = VehicleDatabase.inMemory()
        let cache = CarImageCache(database: database)
        cache.save(bytes(1), for: vin, angle: 0)
        cache.forget(vin: vin)

        cache.save(bytes(2), for: vin, angle: 0)
        await cache.waitUntilIdle()

        #expect(database.images.loadVehicleImage(for: vin, angle: 0)?.data == bytes(2))
    }
}
