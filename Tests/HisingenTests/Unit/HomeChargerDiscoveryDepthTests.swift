import Foundation
import Testing
@testable import Hisingen

/// S15 — discovery beyond NexBlue's `<device>_charging_state` shape. A device registry groups
/// an Easee-style charger into one device; the status sensor anchors it and the switch is only
/// mapped when every status option can confirm a command.
@Suite("Home Assistant charger discovery depth")
struct HomeChargerDiscoveryDepthTests {
    private let entityIDs = [
        "sensor.garage_charger_status",
        "sensor.garage_charger_power",
        "sensor.garage_charger_session_energy",
        "sensor.garage_charger_lifetime_energy",
        "sensor.garage_charger_current_limit",
        "switch.garage_charger_charging",
        "binary_sensor.garage_charger_enabled",
        "binary_sensor.garage_charger_cable_locked"
    ]

    private func registry() -> [String: HADeviceEntity] {
        Dictionary(uniqueKeysWithValues: entityIDs.map { id in
            (id, HADeviceEntity(
                entityID: id, deviceID: "easee-device-1", deviceName: "Garage charger",
                manufacturer: "Easee", model: "Charge", serial: "EASEE-123"
            ))
        })
    }

    @Test
    func anEaseeStyleDeviceIsDiscoveredAndMapped() throws {
        let states = try fixtureStates("home-assistant-states-easee")
        let chargers = HomeChargerDiscovery.chargers(in: states, devices: registry())

        let charger = try #require(chargers.first)
        #expect(chargers.count == 1)
        #expect(charger.id == "EASEE-123")
        #expect(charger.name == "Easee Garage charger")
        #expect(charger.entities == HomeChargerEntityMap(
            chargingState: "sensor.garage_charger_status",
            power: "sensor.garage_charger_power",
            sessionEnergy: "sensor.garage_charger_session_energy",
            lifetimeEnergy: "sensor.garage_charger_lifetime_energy",
            currentLimit: "sensor.garage_charger_current_limit",
            chargingSwitch: "switch.garage_charger_charging",
            chargingEnabled: "binary_sensor.garage_charger_enabled",
            cableLock: "binary_sensor.garage_charger_cable_locked"
        ))
        #expect(charger.missing.isEmpty)
    }

    @Test
    func theNexBluePrefixRouteDoesNotFindTheNewShape() throws {
        // The point of the device route: an anchor named `_status` is invisible to the old
        // `_charging_state` prefix pass.
        #expect(HomeChargerDiscovery.chargers(in: try fixtureStates("home-assistant-states-easee")).isEmpty)
    }

    @Test
    func anUnknownStatusOptionWithholdsTheSwitch() throws {
        var states = try fixtureStates("home-assistant-states-easee")
        let index = try #require(states.firstIndex { $0.entityID == "sensor.garage_charger_status" })
        states[index] = HAEntityState(
            entityID: "sensor.garage_charger_status", state: "charging",
            attributes: [
                "options": .array([.string("disconnected"), .string("connected"),
                                   .string("charging"), .string("awaiting_start")]),
                "device_class": .string("enum"),
                "friendly_name": .string("Garage charger status")
            ],
            lastChanged: states[index].lastChanged,
            lastUpdated: states[index].lastUpdated,
            lastReported: states[index].lastReported
        )

        let charger = try #require(HomeChargerDiscovery.chargers(in: states, devices: registry()).first)

        #expect(charger.entities.chargingState == "sensor.garage_charger_status")
        #expect(charger.entities.power == "sensor.garage_charger_power")
        // A state Hisingen cannot read cannot confirm a start or pause, so no switch is offered.
        #expect(charger.entities.chargingSwitch == nil)
        #expect(charger.missing == ["charging switch"])
    }

    @Test
    func aDeviceWithoutPowerOrSessionEnergyIsNotOffered() throws {
        let states = try fixtureStates("home-assistant-states-easee").filter {
            $0.entityID != "sensor.garage_charger_power"
                && $0.entityID != "sensor.garage_charger_session_energy"
        }

        #expect(HomeChargerDiscovery.chargers(in: states, devices: registry()).isEmpty)
    }

    @Test
    func anUnrelatedDeviceWithAStatusAndSwitchIsNotACharger() {
        let states = [
            HAEntityState(entityID: "sensor.media_room_status", state: "idle",
                          attributes: ["options": .array([.string("idle"), .string("playing")]),
                                       "friendly_name": .string("Media room status")]),
            HAEntityState(entityID: "switch.media_room_power", state: "on",
                          attributes: ["friendly_name": .string("Media room power")])
        ]
        let devices = Dictionary(uniqueKeysWithValues: states.map { state in
            (state.entityID, HADeviceEntity(entityID: state.entityID, deviceID: "media-device",
                                            deviceName: "Media room", manufacturer: nil, model: nil, serial: nil))
        })

        #expect(HomeChargerDiscovery.chargers(in: states, devices: devices).isEmpty)
    }
}
