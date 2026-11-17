"""Drives the Home Assistant glue (``runtime.py``) against a fake Home Assistant.

Home Assistant is not installed in CI, so the few modules the glue imports are replaced with small
stand-ins. This does not prove the glue works inside a real Home Assistant, which is on the live
checklist; it proves the glue wires the tested engine, planner and recorder together correctly:
services answer with the sensor's own fields, a restart reads the charger before it commands, and a
pause survives the restart.
"""
from __future__ import annotations

import asyncio
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

T0 = datetime(2026, 11, 16, 18, 0, tzinfo=timezone.utc)


class Clock:
    now = T0


class FakeState:
    def __init__(self, state: str, attributes: dict[str, Any] | None, stamp: datetime) -> None:
        self.state = state
        self.attributes = attributes or {}
        self.last_updated = stamp
        self.last_reported = stamp


class ServiceValidationError(Exception):
    pass


def _install_stubs() -> None:
    """Minimal stand-ins for the handful of Home Assistant and voluptuous names runtime.py imports."""
    vol = types.ModuleType("voluptuous")

    class Schema:
        def __init__(self, schema: Any, extra: Any = None) -> None:
            self.schema = schema

        def __call__(self, data: Any) -> Any:
            return data

    vol.Schema = Schema
    vol.Required = lambda key, **_: key
    vol.Optional = lambda key, **kwargs: key
    vol.In = lambda values: (lambda value: value)
    vol.Coerce = lambda kind: kind
    vol.Any = lambda *args: args
    vol.ALLOW_EXTRA = 1
    sys.modules["voluptuous"] = vol

    ha = types.ModuleType("homeassistant")
    const = types.ModuleType("homeassistant.const")
    const.EVENT_HOMEASSISTANT_STARTED = "homeassistant_started"
    core = types.ModuleType("homeassistant.core")
    core.Event = object
    core.HomeAssistant = object
    core.ServiceCall = object

    class SupportsResponse:
        OPTIONAL = "optional"

    core.SupportsResponse = SupportsResponse
    core.callback = lambda func: func
    exceptions = types.ModuleType("homeassistant.exceptions")
    exceptions.ServiceValidationError = ServiceValidationError
    helpers = types.ModuleType("homeassistant.helpers")
    cv = types.ModuleType("homeassistant.helpers.config_validation")
    cv.entity_id = str
    cv.string = str
    helpers.config_validation = cv
    event = types.ModuleType("homeassistant.helpers.event")
    event.async_track_state_change_event = lambda hass, entities, action: (lambda: None)
    event.async_track_time_interval = lambda hass, action, interval: (lambda: None)
    storage = types.ModuleType("homeassistant.helpers.storage")

    class Store:
        saved: dict[str, Any] | None = None

        def __init__(self, hass: Any, version: int, key: str) -> None:
            self.hass = hass

        async def async_load(self) -> Any:
            return self.hass.persisted

        async def async_save(self, data: Any) -> None:
            self.hass.persisted = _roundtrip(data)

        def async_delay_save(self, data_func: Any, delay: float = 0) -> None:
            self.hass.persisted = _roundtrip(data_func())

    storage.Store = Store
    util = types.ModuleType("homeassistant.util")
    dt = types.ModuleType("homeassistant.util.dt")
    dt.utcnow = lambda: Clock.now
    dt.as_local = lambda moment: moment
    dt.as_utc = lambda moment: moment.astimezone(timezone.utc)
    dt.parse_datetime = lambda text: datetime.fromisoformat(text) if text else None
    util.dt = dt
    for name, module in {
        "homeassistant": ha, "homeassistant.const": const, "homeassistant.core": core,
        "homeassistant.exceptions": exceptions, "homeassistant.helpers": helpers,
        "homeassistant.helpers.config_validation": cv, "homeassistant.helpers.event": event,
        "homeassistant.helpers.storage": storage, "homeassistant.util": util, "homeassistant.util.dt": dt,
    }.items():
        sys.modules[name] = module


def _roundtrip(data: Any) -> Any:
    import json

    return json.loads(json.dumps(data))


_install_stubs()

from custom_components.hisingen_home_charging import runtime as runtime_module  # noqa: E402


class FakeHass:
    def __init__(self) -> None:
        self.persisted: Any = None
        self.states_table: dict[str, FakeState] = {}
        self.published: dict[str, tuple[str, dict[str, Any]]] = {}
        self.calls: list[tuple[str, str, dict[str, Any]]] = []
        self.registered: dict[str, Any] = {}
        self.is_running = False
        self.config = types.SimpleNamespace(currency="SEK")
        self.tibber_prices: list[tuple[datetime, float]] = []
        self.states = types.SimpleNamespace(get=self.states_table.get, async_set=self._publish)
        self.services = types.SimpleNamespace(
            has_service=lambda domain, name: (domain, name) == ("tibber", "get_prices"),
            async_call=self._call, async_register=self._register,
        )
        self.bus = types.SimpleNamespace(async_listen_once=lambda *_: None)

    def _publish(self, entity_id: str, state: str, attributes: dict[str, Any]) -> None:
        self.published[entity_id] = (state, attributes)

    def _register(self, domain: str, name: str, handler: Any, **_: Any) -> None:
        self.registered[name] = handler

    async def _call(self, domain: str, service: str, data: dict[str, Any], blocking: bool = False,
                    return_response: bool = False) -> Any:
        self.calls.append((domain, service, data))
        if (domain, service) == ("tibber", "get_prices"):
            return {"prices": {"Home": [{"start_time": t.isoformat(), "price": p} for t, p in self.tibber_prices]}}
        return None

    def async_create_task(self, coro: Any) -> Any:
        return asyncio.ensure_future(coro)

    def set_charger(self, status: str, power: float = 0.0, energy: float = 0.0, stamp: datetime | None = None) -> None:
        at = stamp or Clock.now
        self.states_table["sensor.nx1_charging_state"] = FakeState(status, {}, at)
        self.states_table["sensor.nx1_power"] = FakeState(str(power), {"unit_of_measurement": "kW"}, at)
        self.states_table["sensor.nx1_energy"] = FakeState(str(energy), {"unit_of_measurement": "kWh"}, at)
        self.states_table["switch.nx1_charging"] = FakeState("on" if status in ("charging", "lb_waiting", "ev_waiting") else "off", {}, at)

    def switch_commands(self) -> list[str]:
        return [service for domain, service, _ in self.calls if domain == "switch"]


class Call:
    def __init__(self, data: dict[str, Any]) -> None:
        self.data = data


def plan_data(deadline_minutes: float = 600, target: float = 18.0) -> dict[str, Any]:
    return {
        "plan_id": "plan-1", "charger_id": "NX1",
        "charger": {"switch": "switch.nx1_charging", "charging_state": "sensor.nx1_charging_state",
                    "power": "sensor.nx1_power", "session_energy": "sensor.nx1_energy"},
        "target": {"type": "add_kwh", "value": target}, "deadline": (T0 + timedelta(minutes=deadline_minutes)).isoformat(),
        "time_zone": "Europe/Stockholm", "vehicle": {"usable_capacity_kwh": 75, "charging_loss_factor": 1.1},
        "price": {"tibber_home": None, "network_fee_ore_per_kwh": 0}, "rate_hint_kw": 7.2,
    }


def cheap_now() -> list[tuple[datetime, float]]:
    return [(T0 + timedelta(minutes=15 * i), 0.2 if i < 12 else 2.0) for i in range(44)]


def run(coro: Any) -> Any:
    return asyncio.run(coro)


class RuntimeSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        Clock.now = T0
        self.hass = FakeHass()
        self.hass.tibber_prices = cheap_now()

    async def start(self) -> runtime_module.Runtime:
        runtime = runtime_module.Runtime(self.hass)
        await runtime.async_start()
        return runtime

    def test_submit_answers_with_the_sensor_fields_and_starts_the_charger_once(self):
        async def scenario():
            self.hass.set_charger("connected")
            runtime = await self.start()
            response = await runtime._svc_submit(Call(plan_data()))
            self.assertIn(response["state"], {"scheduled", "charging"})
            attributes = response["attributes"]
            self.assertEqual(attributes["plan_id"], "plan-1")
            self.assertEqual(attributes["target"], {"type": "add_kwh", "value": 18.0})
            self.assertTrue(attributes["windows"])
            self.assertEqual(attributes["currency"], "SEK")
            self.assertEqual(self.hass.switch_commands(), ["turn_on"])
            # The same words land on the sensor Hisingen reads.
            sensor = self.hass.published["sensor.hisingen_home_charging_plan_nx1"]
            self.assertEqual(sensor[0], response["state"])
        run(scenario())

    def test_a_restart_reads_the_charger_before_commanding_and_sends_nothing_it_already_obeyed(self):
        async def scenario():
            self.hass.set_charger("connected")
            first = await self.start()
            await first._svc_submit(Call(plan_data()))
            self.assertEqual(self.hass.switch_commands(), ["turn_on"])
            # Home Assistant restarts. The charger obeyed while it was down.
            Clock.now = T0 + timedelta(minutes=5)
            self.hass.set_charger("charging", power=7.2, energy=0.6)
            before = len(self.hass.switch_commands())
            second = await self.start()
            await second._evaluate("NX1")
            self.assertEqual(len(self.hass.switch_commands()), before)
            self.assertEqual(self.hass.published["sensor.hisingen_home_charging_plan_nx1"][0], "charging")
            self.assertAlmostEqual(second.plans["NX1"].delivered_kwh, 0.6, places=3)
        run(scenario())

    def test_a_charger_not_yet_loaded_after_a_restart_is_never_commanded(self):
        async def scenario():
            self.hass.set_charger("connected")
            first = await self.start()
            await first._svc_submit(Call(plan_data()))
            self.hass.calls.clear()
            self.hass.states_table.clear()    # the integration has not loaded its entities yet
            second = await self.start()
            await second._evaluate("NX1")
            self.assertEqual(self.hass.switch_commands(), [])
            self.assertEqual(self.hass.published["sensor.hisingen_home_charging_plan_nx1"][0], "attention")
        run(scenario())

    def test_pause_holds_across_a_restart_and_resume_releases_it(self):
        async def scenario():
            self.hass.set_charger("charging", power=7.2, energy=1.0)
            first = await self.start()
            await first._svc_submit(Call(plan_data()))
            await first._svc_pause(Call({"charger_id": "NX1"}))
            self.assertIn("turn_off", self.hass.switch_commands())
            self.hass.calls.clear()
            Clock.now = T0 + timedelta(minutes=2)
            self.hass.set_charger("connected", power=0, energy=1.0)
            second = await self.start()
            await second._evaluate("NX1")
            self.assertEqual(self.hass.switch_commands(), [])
            self.assertEqual(self.hass.published["sensor.hisingen_home_charging_plan_nx1"][0], "holding")
            await second._svc_resume(Call({"charger_id": "NX1"}))
            self.assertEqual(self.hass.switch_commands(), ["turn_on"])
        run(scenario())

    def test_preview_changes_nothing_and_sends_nothing(self):
        async def scenario():
            self.hass.set_charger("connected")
            runtime = await self.start()
            response = await runtime._svc_preview(Call(plan_data()))
            self.assertTrue(response["attributes"]["windows"])
            self.assertNotIn("NX1", runtime.plans)
            self.assertEqual(self.hass.switch_commands(), [])
        run(scenario())

    def test_a_percentage_plan_without_a_fresh_battery_sensor_is_refused(self):
        async def scenario():
            self.hass.set_charger("connected")
            runtime = await self.start()
            data = plan_data()
            data["target"] = {"type": "reach_percent", "value": 80.0}
            with self.assertRaises(ServiceValidationError):
                await runtime._svc_submit(Call(data))
            data["charger"]["vehicle_battery"] = "sensor.polestar_battery"
            self.hass.states_table["sensor.polestar_battery"] = FakeState(
                "62", {"unit_of_measurement": "%"}, T0 - timedelta(hours=3))
            with self.assertRaises(ServiceValidationError):
                await runtime._svc_submit(Call(data))
            self.hass.states_table["sensor.polestar_battery"] = FakeState("62", {"unit_of_measurement": "%"}, T0)
            response = await runtime._svc_submit(Call(data))
            self.assertEqual(response["attributes"]["target"]["type"], "reach_percent")
        run(scenario())

    def test_finished_sessions_are_recorded_while_no_plan_exists_and_survive_a_restart(self):
        async def scenario():
            self.hass.set_charger("connected", energy=0.0)
            runtime = await self.start()
            await runtime._svc_register(Call({"charger_id": "NX1", "charger": plan_data()["charger"]}))
            for minute in range(1, 61):
                Clock.now = T0 + timedelta(minutes=minute)
                self.hass.set_charger("charging", power=7.2, energy=round(0.12 * minute, 4))
                await runtime._evaluate("NX1")
            Clock.now = T0 + timedelta(minutes=61)
            self.hass.set_charger("finished", power=0, energy=7.2)
            await runtime._evaluate("NX1")
            Clock.now = T0 + timedelta(minutes=120)
            self.hass.set_charger("finished", power=0, energy=7.2)
            await runtime._evaluate("NX1")
            restarted = await self.start()
            response = await restarted._svc_sessions(Call({"charger_id": "NX1"}))
            self.assertEqual(len(response["sessions"]), 1)
            session = response["sessions"][0]
            self.assertAlmostEqual(session["energy_kwh"], 7.2, places=2)
            self.assertTrue(session["intervals"])
        run(scenario())


if __name__ == "__main__":
    unittest.main()
