import Foundation
import Testing
@testable import Hisingen

struct PolestarLocationWeatherFixtureTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "polestar-lw-" + name, withExtension: "bin"))
        return try Data(contentsOf: url)
    }

    @Test func referenceClientLocationLayouts() throws {
        for name in ["compact", "wrapped-location", "wrapped-location-5", "shifted"] {
            let result = try #require(PolestarGRPC.parseLocation(fixture(name)))
            #expect(result.latitude == 55.5)
            #expect(result.longitude == -12.5)
            #expect(result.timestamp == Date(timeIntervalSince1970: name == "shifted" ? 2_000_000_000 : 2_000_000_000.5))
            #expect(result.heading == nil)
        }
    }

    @Test func referenceClientWeatherLayouts() throws {
        for name in ["weather", "wrapped-weather"] {
            let result = try #require(PolestarGRPC.parseWeather(fixture(name)))
            #expect(result.temperatureCelsius == -5.5)
            #expect(result.timestamp == Date(timeIntervalSince1970: 2_000_000_000))
            #expect(result.condition == nil)
        }
    }

    @Test func zeroAndFloatValuesAreReadings() throws {
        var location = Protobuf.floatField(1, 0)
        location.append(Protobuf.floatField(2, 0))
        location.append(Protobuf.messageField(3, Data()))
        let result = try #require(PolestarGRPC.parseLocation(location))
        #expect(result.longitude == 0 && result.latitude == 0)
        #expect(result.timestamp == Date(timeIntervalSince1970: 0))
        var weather = Protobuf.intField(1, 0)
        weather.append(Protobuf.floatField(2, 0))
        #expect(PolestarGRPC.parseWeather(weather)?.temperatureCelsius == 0)
        #expect(PolestarGRPC.parseWeather(weather)?.timestamp == Date(timeIntervalSince1970: 0))
    }

    @Test func invalidAndUnknownValues() {
        for value in [Double.nan, Double.infinity, -Double.infinity, 181] {
            var data = Protobuf.doubleField(1, value)
            data.append(Protobuf.doubleField(2, 0))
            #expect(PolestarGRPC.parseLocation(data) == nil)
        }
        var latitude = Protobuf.doubleField(1, 0)
        latitude.append(Protobuf.doubleField(2, 91))
        #expect(PolestarGRPC.parseLocation(latitude) == nil)
        var bounds = Protobuf.doubleField(1, -180)
        bounds.append(Protobuf.doubleField(2, 90))
        bounds.append(Protobuf.doubleField(6, 123))
        #expect(PolestarGRPC.parseLocation(bounds)?.heading == nil)
        #expect(PolestarGRPC.parseLocation(bounds)?.altitudeMeters == nil)
        var integer = Protobuf.intField(1, -125_000_000)
        integer.append(Protobuf.intField(2, 555_000_000))
        #expect(PolestarGRPC.parseLocation(integer) == nil)
        var truncated = bounds
        truncated.append(0x11)
        #expect(PolestarGRPC.parseLocation(truncated) == nil)
        #expect(PolestarGRPC.parseWeather(Protobuf.doubleField(2, .nan)) == nil)
        #expect(PolestarGRPC.parseWeather(Protobuf.intField(2, 15)) == nil)
    }
    @Test func malformedTimestampAndAmbiguousLayoutsAreRejected() {
        let coordinates = Protobuf.doubleField(1, 10) + Protobuf.doubleField(2, 20)
        #expect(PolestarGRPC.parseLocation(coordinates + Protobuf.messageField(3, Data([0x08, 0x80]))) == nil)
        #expect(PolestarGRPC.parseLocation(coordinates + Protobuf.messageField(3, Protobuf.doubleField(1, 1))) == nil)
        #expect(PolestarGRPC.parseLocation(coordinates + Protobuf.messageField(3, Protobuf.intField(2, 1_000_000_000))) == nil)
        #expect(PolestarGRPC.parseLocation(coordinates + Protobuf.doubleField(3, 30)) == nil)
        let nested = Protobuf.messageField(2, coordinates) + Protobuf.messageField(5, coordinates)
        #expect(PolestarGRPC.parseLocation(nested) == nil)
        #expect(PolestarGRPC.parseWeather(Protobuf.intField(1, 123)) == nil)
    }

    @Test func scalarOrderAndUnknownFields() throws {
        let coordinates = Protobuf.doubleField(1, 10) + Protobuf.floatField(1, -12.5)
            + Protobuf.floatField(2, 55.5) + Protobuf.doubleField(40, 88)
            + Protobuf.doubleField(4, 180) + Protobuf.doubleField(6, 123)
        let result = try #require(PolestarGRPC.parseLocation(coordinates))
        #expect(result.longitude == -12.5 && result.latitude == 55.5)
        #expect(result.heading == nil && result.altitudeMeters == nil)
        #expect(PolestarGRPC.parseLocation(coordinates + Protobuf.intField(1, 5)) == nil)
        let weather = Protobuf.doubleField(2, 12.5) + Protobuf.floatField(2, -5.5)
            + Protobuf.intField(3, 1)
        #expect(PolestarGRPC.parseWeather(weather)?.temperatureCelsius == -5.5)
        #expect(PolestarGRPC.parseWeather(weather)?.condition == nil)
        #expect(PolestarGRPC.parseWeather(weather + Protobuf.intField(2, 5)) == nil)
    }

    @Test func weatherFiniteAndTimestampWireTypes() throws {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(PolestarGRPC.parseWeather(Protobuf.doubleField(2, value)) == nil)
        }
        let report = Protobuf.doubleField(1, 123) + Protobuf.doubleField(2, 1)
        let result = try #require(PolestarGRPC.parseWeather(report))
        #expect(result.timestamp == nil)
        #expect(result.temperatureCelsius == 1)
        #expect(PolestarGRPC.parseWeather(Protobuf.messageField(1, Data([0x08, 0x80]))) == nil)
    }

    @Test func sanitizedOwnerCaptureTopology() throws {
        let location = try #require(PolestarGRPC.parseLocation(fixture("p2-owner-location")))
        #expect(location.latitude == 55.5 && location.longitude == -12.5)
        #expect(location.timestamp == Date(timeIntervalSince1970: 2_000_000_000))
        let weather = try #require(PolestarGRPC.parseWeather(fixture("p2-owner-weather")))
        #expect(weather.temperatureCelsius == -5.5)
        #expect(weather.timestamp == Date(timeIntervalSince1970: 2_000_000_000))
        var conflicting = Protobuf.doubleField(2, 1) + Protobuf.doubleField(3, 2)
        conflicting.append(Protobuf.messageField(5, Protobuf.doubleField(1, 3) + Protobuf.doubleField(2, 2)))
        #expect(PolestarGRPC.parseLocation(conflicting) == nil)
    }

}
