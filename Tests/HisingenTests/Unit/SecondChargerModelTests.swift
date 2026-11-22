import Foundation
import Testing
@testable import Hisingen

/// Two chargers reaching the model: both listed, one holding the live connection, the card showing
/// the charger that belongs to the car in front of it, and a command going to the charger it names.
@Suite(.serialized)
@MainActor
struct SecondChargerModelTests {
    private let vin = "YSMCHARGERTEST00001"

    private func pairing(
        chargerID: String, name: String, locationID: String?, locationAlias: String = "Home"
    ) -> HomeChargingPairing {
        HomeChargingPairing(
            baseURL: "http://homeassistant.local:8123", chargerID: chargerID, chargerName: name,
            entities: HomeChargerEntityMap(chargingState: "sensor.\(chargerID)_state",
                                           chargingSwitch: "switch.\(chargerID)"),
            vin: vin, locationID: locationID, locationAlias: locationAlias,
            timeZoneIdentifier: "Europe/Stockholm")
    }

    private func configuredStore(_ label: String, pairings: [HomeChargingPairing]) throws -> ScopedPreferences {
        let scoped = ScopedPreferences(label: label)
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        for entry in pairings { store.upsert(entry) }
        try store.saveToken("test-token")
        return scoped
    }

    private func model(_ scoped: ScopedPreferences, transport: HomeAssistantTransport) -> HomeChargingModel {
        HomeChargingModel(
            preferences: scoped.store, database: VehicleDatabase.inMemory(),
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil,
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, observesWake: false))
    }

    // MARK: - Listing and selection

    @Test
    func bothPairingsLoadAndTheFirstHoldsTheConnection() throws {
        let garage = pairing(chargerID: "nexblue-1", name: "Garage", locationID: "home-loc")
        let carport = pairing(chargerID: "nexblue-2", name: "Carport", locationID: "work-loc", locationAlias: "Work")
        let scoped = try configuredStore("SecondChargerModelTwo", pairings: [garage, carport])

        let model = model(scoped, transport: RecordingTransport())

        #expect(model.pairings.map(\.chargerName) == ["Garage", "Carport"])
        #expect(model.pairing?.identity == garage.identity)
    }

    @Test
    func selectingTheSecondChargerMovesTheConnection() throws {
        let garage = pairing(chargerID: "nexblue-1", name: "Garage", locationID: "home-loc")
        let carport = pairing(chargerID: "nexblue-2", name: "Carport", locationID: "work-loc")
        let scoped = try configuredStore("SecondChargerModelSelect", pairings: [garage, carport])
        let model = model(scoped, transport: RecordingTransport())

        #expect(model.selectCharger(identity: carport.identity))
        #expect(model.pairing?.identity == carport.identity)
        // Both are still known; switching does not remove the first.
        #expect(model.pairings.count == 2)
        model.stop()
    }

    @Test
    func unpairingOneChargerKeepsTheOtherAndItTakesOver() throws {
        let garage = pairing(chargerID: "nexblue-1", name: "Garage", locationID: "home-loc")
        let carport = pairing(chargerID: "nexblue-2", name: "Carport", locationID: "work-loc")
        let scoped = try configuredStore("SecondChargerModelUnpair", pairings: [garage, carport])
        let model = model(scoped, transport: RecordingTransport())

        model.unpair(identity: garage.identity)

        #expect(model.pairings.map(\.chargerName) == ["Carport"])
        #expect(model.pairing?.identity == carport.identity)
        // The removal is on disk too, not just in memory.
        let reloaded = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        #expect(reloaded.pairings.map(\.chargerName) == ["Carport"])
        model.stop()
    }

    // MARK: - Which charger the card shows

    @Test
    func theCardShowsTheChargerAtTheCarsOwnLocationEvenWhenAnotherIsConnected() throws {
        let garage = pairing(chargerID: "nexblue-1", name: "Garage", locationID: "work-loc", locationAlias: "Work")
        let carport = pairing(chargerID: "nexblue-2", name: "Carport", locationID: "home-loc")
        let scoped = try configuredStore("SecondChargerModelCard", pairings: [garage, carport])
        let model = model(scoped, transport: RecordingTransport())

        var state = vehicle(vin: vin, connection: .connected)
        state.chargeLocationPresence = ChargeLocationPresence(
            locationID: "home-loc", alias: "Home", since: nil, source: .proximity)

        // Garage is live, but the car is parked at the carport's location.
        #expect(model.pairing?.identity == garage.identity)
        #expect(model.cardInput(for: state)?.pairing.identity == carport.identity)
        #expect(model.shouldShow(for: state))
        model.stop()
    }

    @Test
    func aChargerPairedToAnotherVehicleIsNotOfferedForThisOne() throws {
        let scoped = ScopedPreferences(label: "SecondChargerModelOtherCar")
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        store.upsert(HomeChargingPairing(
            baseURL: "http://homeassistant.local:8123", chargerID: "nexblue-1", chargerName: "Garage",
            entities: HomeChargerEntityMap(chargingSwitch: "switch.nexblue-1"),
            vin: "SOMEONEELSE", locationID: "home-loc", locationAlias: "Home"))
        try store.saveToken("test-token")
        let model = model(scoped, transport: RecordingTransport())
        var state = vehicle(vin: vin, connection: .connected)
        state.chargeLocationPresence = ChargeLocationPresence(
            locationID: "home-loc", alias: "Home", since: nil, source: .proximity)

        #expect(model.cardInput(for: state) == nil)
        model.stop()
    }

    // MARK: - Commands

    @Test
    func aCommandGoesToTheChargerItNames() async throws {
        let garage = pairing(chargerID: "nexblue-1", name: "Garage", locationID: "home-loc")
        let carport = pairing(chargerID: "nexblue-2", name: "Carport", locationID: "work-loc")
        let scoped = try configuredStore("SecondChargerModelCommand", pairings: [garage, carport])
        let transport = RecordingTransport()
        let model = model(scoped, transport: transport)

        await model.send(.pause, for: carport.identity)

        // The service call names the carport's switch, and the model is now live on the carport
        // because the command selected it first.
        #expect(transport.switchEntities.contains("switch.nexblue-2"))
        #expect(transport.switchEntities.contains("switch.nexblue-1") == false)
        #expect(model.pairing?.identity == carport.identity)
        model.stop()
    }

    // MARK: - Transport

    /// Answers every Home Assistant request with a refusal, recording the switch entities it was
    /// asked to act on. Enough to prove which charger a command was aimed at without a network.
    private final class RecordingTransport: HomeAssistantTransport, @unchecked Sendable {
        private var entities: [String] = []

        private func append(_ entity: String) { entities.append(entity) }

        var switchEntities: [String] { entities }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url ?? URL(string: "http://homeassistant.local:8123/")!
            if request.httpMethod == "POST", url.path.contains("/api/services/switch/") {
                if let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll),
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let entity = object["entity_id"] as? String {
                    append(entity)
                }
                return (Data("[]".utf8), Self.response(url, status: 200))
            }
            if url.path.hasPrefix("/api/states/") {
                return (Data("{\"message\":\"Entity not found.\"}".utf8), Self.response(url, status: 404))
            }
            return (Data("{}".utf8), Self.response(url, status: 200))
        }

        private static func response(_ url: URL, status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }

        private static func readAll(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }
}
