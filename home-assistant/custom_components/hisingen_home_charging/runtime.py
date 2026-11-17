"""Home Assistant side of the component: storage, services, listeners and the plan sensor.

Everything that decides anything lives in ``engine``, ``planner`` and ``sessions``. This module
reads entity states into those, carries out the one command the engine may ask for, and publishes
the result where Hisingen reads it.
"""
from __future__ import annotations

import asyncio
import logging
import re
from datetime import datetime, timedelta
from typing import Any

import voluptuous as vol
from homeassistant.const import EVENT_HOMEASSISTANT_STARTED
from homeassistant.core import Event, HomeAssistant, ServiceCall, SupportsResponse, callback
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.event import async_track_state_change_event, async_track_time_interval
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util

from . import engine, planner
from .const import (
    DOMAIN,
    PHASE_CANCELLED,
    PHASE_IDLE,
    STORE_KEY,
    STORE_VERSION,
    TARGET_ADD_KWH,
    TARGET_REACH_PERCENT,
    TERMINAL_PHASES,
)
from .sessions import SessionRecorder, session_average_power_kw

_LOGGER = logging.getLogger(__name__)

VERSION = "1.0.0"
PRICE_SOURCE = "tibber.get_prices"
TICK = timedelta(seconds=60)
PRICE_REFRESH = timedelta(minutes=15)

CHARGER_ENTITIES = vol.Schema(
    {
        vol.Optional("switch"): cv.entity_id,
        vol.Optional("charging_state"): cv.entity_id,
        vol.Optional("power"): cv.entity_id,
        vol.Optional("session_energy"): cv.entity_id,
        vol.Optional("charging_enabled"): cv.entity_id,
        vol.Optional("vehicle_battery"): cv.entity_id,
    }
)
CHARGER_ID = vol.Schema({vol.Required("charger_id"): cv.string})
PLAN_SCHEMA = vol.Schema(
    {
        vol.Required("plan_id"): cv.string,
        vol.Required("charger_id"): cv.string,
        vol.Required("charger"): CHARGER_ENTITIES,
        vol.Required("target"): vol.Schema(
            {vol.Required("type"): vol.In([TARGET_ADD_KWH, TARGET_REACH_PERCENT]), vol.Required("value"): vol.Coerce(float)}
        ),
        vol.Required("deadline"): cv.string,
        vol.Optional("time_zone", default="UTC"): cv.string,
        vol.Optional("vehicle", default={}): dict,
        vol.Optional("price", default={}): dict,
        vol.Optional("rate_hint_kw", default=7.4): vol.Coerce(float),
    }
)
REGISTER_SCHEMA = vol.Schema(
    {
        vol.Required("charger_id"): cv.string,
        vol.Required("charger"): CHARGER_ENTITIES,
        vol.Optional("tibber_home"): vol.Any(None, cv.string),
    }
)
SESSIONS_SCHEMA = vol.Schema({vol.Required("charger_id"): cv.string, vol.Optional("since"): cv.string})


def slug(text: str) -> str:
    """The same rule as the Swift app, so the plan sensor's name needs no handshake."""
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def plan_entity_id(charger_id: str) -> str:
    return f"sensor.hisingen_home_charging_plan_{slug(charger_id)}"


def _stamp(state: Any) -> datetime | None:
    if state is None:
        return None
    return getattr(state, "last_reported", None) or state.last_updated


def _number(state: Any, *, scale_from: dict[str, float] | None = None) -> float | None:
    if state is None or state.state in ("unavailable", "unknown", ""):
        return None
    try:
        value = float(state.state)
    except ValueError:
        return None
    unit = state.attributes.get("unit_of_measurement")
    if scale_from and unit in scale_from:
        value *= scale_from[unit]
    return value


async def async_setup_runtime(hass: HomeAssistant, config: dict[str, Any]) -> bool:
    runtime = Runtime(hass)
    hass.data[DOMAIN] = runtime
    await runtime.async_start()
    return True


class Runtime:
    def __init__(self, hass: HomeAssistant) -> None:
        self.hass = hass
        self._store: Store = Store(hass, STORE_VERSION, STORE_KEY)
        self.chargers: dict[str, dict[str, Any]] = {}
        self.plans: dict[str, engine.Plan] = {}
        self.recorders: dict[str, SessionRecorder] = {}
        self._listeners: dict[str, Any] = {}
        self._prices: dict[str, tuple[datetime, list[planner.PriceSlot]]] = {}
        self._lock = asyncio.Lock()

    # -- lifecycle -----------------------------------------------------------------------------

    async def async_start(self) -> None:
        data = await self._store.async_load() or {}
        self.chargers = dict(data.get("chargers", {}))
        for charger_id, raw in data.get("plans", {}).items():
            try:
                self.plans[charger_id] = engine.Plan.from_dict(raw)
            except (KeyError, ValueError, TypeError):
                _LOGGER.warning("Dropping an unreadable saved plan for %s", charger_id)
        for charger_id, raw in data.get("recorders", {}).items():
            try:
                self.recorders[charger_id] = SessionRecorder.from_dict(charger_id, raw)
            except (KeyError, ValueError, TypeError):
                self.recorders[charger_id] = SessionRecorder(charger_id)
        self._register_services()
        for charger_id in self.chargers:
            self._listen(charger_id)
            self._publish(charger_id)
        async_track_time_interval(self.hass, self._on_tick, TICK)
        if self.hass.is_running:
            self.hass.async_create_task(self._evaluate_all())
        else:
            self.hass.bus.async_listen_once(
                EVENT_HOMEASSISTANT_STARTED, lambda _event: self.hass.async_create_task(self._evaluate_all())
            )

    def _snapshot_for_save(self) -> dict[str, Any]:
        return {
            "chargers": self.chargers,
            "plans": {cid: plan.to_dict() for cid, plan in self.plans.items()},
            "recorders": {cid: recorder.to_dict() for cid, recorder in self.recorders.items()},
        }

    def _save_soon(self) -> None:
        self._store.async_delay_save(self._snapshot_for_save, 5)

    async def _save_now(self) -> None:
        await self._store.async_save(self._snapshot_for_save())

    # -- listeners -----------------------------------------------------------------------------

    def _listen(self, charger_id: str) -> None:
        if charger_id in self._listeners:
            self._listeners.pop(charger_id)()
        entities = [e for e in self.chargers[charger_id]["entities"].values() if e]
        if not entities:
            return

        @callback
        def _changed(_event: Event) -> None:
            self.hass.async_create_task(self._evaluate(charger_id))

        self._listeners[charger_id] = async_track_state_change_event(self.hass, entities, _changed)

    async def _on_tick(self, _now: datetime) -> None:
        await self._evaluate_all()

    async def _evaluate_all(self) -> None:
        for charger_id in list(self.chargers):
            await self._evaluate(charger_id)

    # -- reading the charger -------------------------------------------------------------------

    def _read(self, charger_id: str) -> tuple[engine.ChargerSnapshot, engine.BatteryReading, datetime | None]:
        entities = self.chargers[charger_id]["entities"]

        def state(key: str) -> Any:
            entity_id = entities.get(key)
            return self.hass.states.get(entity_id) if entity_id else None

        status_state = state("charging_state")
        energy_state = state("session_energy")
        snapshot = engine.ChargerSnapshot(
            status=None if status_state is None else status_state.state,
            power_kw=_number(state("power"), scale_from={"W": 0.001}),
            energy_kwh=_number(energy_state, scale_from={"Wh": 0.001}),
            timestamp=_stamp(status_state),
        )
        battery_state = state("vehicle_battery")
        percent = _number(battery_state)
        battery = engine.BatteryReading(
            percent=percent if battery_state is not None and battery_state.attributes.get("unit_of_measurement") == "%" else None,
            timestamp=_stamp(battery_state),
        )
        return snapshot, battery, _stamp(energy_state)

    def _history_rates(self, charger_id: str) -> list[float]:
        recorder = self.recorders.get(charger_id)
        if recorder is None:
            return []
        rates = (session_average_power_kw(record) for record in recorder.completed[-5:])
        return [rate for rate in rates if rate]

    # -- prices --------------------------------------------------------------------------------

    async def _slots(self, charger_id: str, deadline: datetime, now: datetime) -> list[planner.PriceSlot]:
        cached = self._prices.get(charger_id)
        local_hour = dt_util.as_local(now).hour
        covers = bool(cached) and bool(cached[1]) and cached[1][-1].end >= deadline
        stale = cached is None or now - cached[0] > PRICE_REFRESH
        # Tomorrow's prices appear in the afternoon: look again every few minutes until they do.
        waiting_for_tomorrow = cached is not None and not covers and local_hour >= 13 and now - cached[0] > timedelta(minutes=5)
        if cached and not stale and not waiting_for_tomorrow:
            return cached[1]
        if not self.hass.services.has_service("tibber", "get_prices"):
            return cached[1] if cached else []
        fmt = "%Y-%m-%d %H:%M:%S"
        data = {
            "start": dt_util.as_local(now - timedelta(minutes=30)).strftime(fmt),
            "end": dt_util.as_local(deadline + timedelta(hours=1)).strftime(fmt),
        }
        try:
            response = await self.hass.services.async_call("tibber", "get_prices", data, blocking=True, return_response=True)
        except Exception:  # noqa: BLE001 - any failure leaves the last prices in place
            _LOGGER.warning("tibber.get_prices failed; keeping the last prices", exc_info=True)
            return cached[1] if cached else []
        slots = self._parse_prices(response, self.chargers[charger_id].get("tibber_home"))
        if slots:
            self._prices[charger_id] = (now, slots)
            return slots
        return cached[1] if cached else []

    @staticmethod
    def _parse_prices(response: Any, home: str | None) -> list[planner.PriceSlot]:
        prices = (response or {}).get("prices") if isinstance(response, dict) else None
        if not isinstance(prices, dict) or not prices:
            return []
        key = home if home in prices else sorted(prices)[0]
        points: list[tuple[datetime, float]] = []
        for entry in prices.get(key) or []:
            start = dt_util.parse_datetime(str(entry.get("start_time", "")))
            try:
                price = float(entry["price"])
            except (KeyError, TypeError, ValueError):
                continue
            if start is not None:
                points.append((dt_util.as_utc(start), price))
        return planner.slots_from_points(points)

    # -- evaluation ----------------------------------------------------------------------------

    async def _evaluate(self, charger_id: str) -> None:
        async with self._lock:
            if charger_id not in self.chargers:
                return
            now = dt_util.utcnow()
            snapshot, battery, energy_stamp = self._read(charger_id)
            recorder = self.recorders.setdefault(charger_id, SessionRecorder(charger_id))
            recorder.observe(energy_stamp or now, snapshot.status, snapshot.energy_kwh, snapshot.power_kw, battery.percent)
            recorder.tick(now, snapshot.status)

            plan = self.plans.get(charger_id)
            if plan is not None and plan.phase not in TERMINAL_PHASES:
                slots = await self._slots(charger_id, plan.deadline, now)
                result = engine.step(plan, snapshot, battery, slots, now, self._history_rates(charger_id))
                if result.command:
                    await self._send(charger_id, result.command)
            self._publish(charger_id)
            self._save_soon()

    async def _send(self, charger_id: str, command: str) -> None:
        entity_id = self.chargers[charger_id]["entities"].get("switch")
        if not entity_id:
            return
        try:
            await self.hass.services.async_call("switch", command, {"entity_id": entity_id}, blocking=True)
        except Exception:  # noqa: BLE001 - the engine retries with backoff and reports it unconfirmed
            _LOGGER.warning("switch.%s on %s failed", command, entity_id, exc_info=True)

    def _publish(self, charger_id: str) -> None:
        plan = self.plans.get(charger_id)
        currency = self.hass.config.currency
        if plan is None:
            state, attributes = PHASE_IDLE, {"charger_id": charger_id, "updated_at": dt_util.utcnow().isoformat()}
        else:
            state, attributes = plan.phase, plan.attributes(currency, PRICE_SOURCE)
        attributes["friendly_name"] = f"Hisingen charging plan {charger_id}"
        self.hass.states.async_set(plan_entity_id(charger_id), state, attributes)

    def _response(self, charger_id: str) -> dict[str, Any]:
        plan = self.plans.get(charger_id)
        if plan is None:
            return {"state": PHASE_IDLE, "attributes": {"charger_id": charger_id}}
        return {"state": plan.phase, "attributes": plan.attributes(self.hass.config.currency, PRICE_SOURCE)}

    # -- services ------------------------------------------------------------------------------

    def _register_services(self) -> None:
        def register(name: str, handler: Any, schema: vol.Schema) -> None:
            self.hass.services.async_register(DOMAIN, name, handler, schema=schema, supports_response=SupportsResponse.OPTIONAL)

        register("register_charger", self._svc_register, REGISTER_SCHEMA)
        register("submit_plan", self._svc_submit, PLAN_SCHEMA)
        register("preview_plan", self._svc_preview, PLAN_SCHEMA)
        register("cancel_plan", self._svc_cancel, CHARGER_ID)
        register("pause_plan", self._svc_pause, CHARGER_ID)
        register("resume_plan", self._svc_resume, CHARGER_ID)
        register("charge_now", self._svc_charge_now, CHARGER_ID)
        register("get_status", self._svc_status, CHARGER_ID)
        register("get_sessions", self._svc_sessions, SESSIONS_SCHEMA)

    def _upsert_charger(self, charger_id: str, entities: dict[str, str], tibber_home: str | None) -> None:
        self.chargers[charger_id] = {"entities": dict(entities), "tibber_home": tibber_home}
        self.recorders.setdefault(charger_id, SessionRecorder(charger_id))
        self._listen(charger_id)

    async def _svc_register(self, call: ServiceCall) -> dict[str, Any]:
        async with self._lock:
            self._upsert_charger(call.data["charger_id"], call.data["charger"], call.data.get("tibber_home"))
        await self._save_now()
        await self._evaluate(call.data["charger_id"])
        return {"registered": True, "version": VERSION}

    def _build_plan(self, data: dict[str, Any], now: datetime) -> engine.Plan:
        deadline = dt_util.parse_datetime(data["deadline"])
        if deadline is None:
            raise ServiceValidationError("The deadline is not a valid date and time.")
        deadline = dt_util.as_utc(deadline)
        if deadline <= now:
            raise ServiceValidationError("The deadline has already passed.")
        vehicle = data.get("vehicle", {})
        return engine.Plan(
            plan_id=data["plan_id"], charger_id=data["charger_id"], target_type=data["target"]["type"],
            target_value=float(data["target"]["value"]), deadline=deadline, time_zone=data["time_zone"],
            usable_capacity_kwh=float(vehicle.get("usable_capacity_kwh", 0) or 0),
            loss_factor=float(vehicle.get("charging_loss_factor", 1.1) or 1.1),
            rate_hint_kw=float(data["rate_hint_kw"]), created_at=now,
        )

    def _validate_target(self, plan: engine.Plan, battery: engine.BatteryReading, now: datetime) -> None:
        if plan.target_type != TARGET_REACH_PERCENT:
            return
        if not self.chargers[plan.charger_id]["entities"].get("vehicle_battery"):
            raise ServiceValidationError("Reach a percentage needs a battery sensor in Home Assistant, and none is configured.")
        if not battery.is_fresh(now):
            raise ServiceValidationError("The battery sensor has not updated recently, so a percentage plan cannot be trusted.")
        if plan.usable_capacity_kwh <= 0:
            raise ServiceValidationError("The usable battery capacity is needed to plan a percentage.")

    async def _svc_submit(self, call: ServiceCall) -> dict[str, Any]:
        data = dict(call.data)
        charger_id = data["charger_id"]
        async with self._lock:
            now = dt_util.utcnow()
            self._upsert_charger(charger_id, data["charger"], (data.get("price") or {}).get("tibber_home"))
            plan = self._build_plan(data, now)
            snapshot, battery, _ = self._read(charger_id)
            self._validate_target(plan, battery, now)
            # Progress counts from now: the counter's current value is the baseline.
            plan.last_energy = snapshot.energy_kwh
            self.plans[charger_id] = plan
        await self._evaluate(charger_id)
        await self._save_now()
        return self._response(charger_id)

    async def _svc_preview(self, call: ServiceCall) -> dict[str, Any]:
        data = dict(call.data)
        charger_id = data["charger_id"]
        async with self._lock:
            now = dt_util.utcnow()
            if charger_id not in self.chargers:
                self._upsert_charger(charger_id, data["charger"], (data.get("price") or {}).get("tibber_home"))
            else:
                self.chargers[charger_id]["entities"] = dict(data["charger"])
            plan = self._build_plan(data, now)
            snapshot, battery, _ = self._read(charger_id)
            self._validate_target(plan, battery, now)
            plan.last_energy = snapshot.energy_kwh
            slots = await self._slots(charger_id, plan.deadline, now)
            engine.step(plan, snapshot, battery, slots, now, self._history_rates(charger_id))
        # Nothing is stored and no command is sent: the plan only existed to be looked at.
        return {"state": plan.phase, "attributes": plan.attributes(self.hass.config.currency, PRICE_SOURCE)}

    async def _svc_cancel(self, call: ServiceCall) -> dict[str, Any]:
        charger_id = call.data["charger_id"]
        async with self._lock:
            plan = self.plans.get(charger_id)
            if plan is not None and plan.phase not in TERMINAL_PHASES:
                plan.phase = PHASE_CANCELLED
                plan.windows = []
                plan.override = False
                plan.updated_at = dt_util.utcnow()
        self._publish(charger_id)
        await self._save_now()
        return self._response(charger_id)

    async def _svc_pause(self, call: ServiceCall) -> dict[str, Any]:
        charger_id = call.data["charger_id"]
        async with self._lock:
            plan = self._active_plan(charger_id)
            plan.hold = True
            plan.override = False
        await self._evaluate(charger_id)
        await self._save_now()
        return self._response(charger_id)

    async def _svc_resume(self, call: ServiceCall) -> dict[str, Any]:
        charger_id = call.data["charger_id"]
        async with self._lock:
            plan = self._active_plan(charger_id)
            plan.hold = False
            plan.last_command = None
        await self._evaluate(charger_id)
        await self._save_now()
        return self._response(charger_id)

    async def _svc_charge_now(self, call: ServiceCall) -> dict[str, Any]:
        charger_id = call.data["charger_id"]
        async with self._lock:
            plan = self._active_plan(charger_id)
            plan.override = True
            plan.hold = False
            plan.last_command = None
        await self._evaluate(charger_id)
        await self._save_now()
        return self._response(charger_id)

    def _active_plan(self, charger_id: str) -> engine.Plan:
        plan = self.plans.get(charger_id)
        if plan is None or plan.phase in TERMINAL_PHASES:
            raise ServiceValidationError("There is no plan running for this charger.")
        return plan

    async def _svc_status(self, call: ServiceCall) -> dict[str, Any]:
        charger_id = call.data["charger_id"]
        self._publish(charger_id)
        return {**self._response(charger_id), "version": VERSION}

    async def _svc_sessions(self, call: ServiceCall) -> dict[str, Any]:
        recorder = self.recorders.get(call.data["charger_id"])
        since = dt_util.parse_datetime(call.data["since"]) if call.data.get("since") else None
        records = recorder.sessions_since(since) if recorder else []
        return {"sessions": records, "version": VERSION}
