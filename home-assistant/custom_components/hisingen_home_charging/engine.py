"""Runs one charging plan: where it stands, what to do next, and what it learned.

Pure Python. Every call to ``step`` reads the charger's actual state first and only then decides
whether a command is needed, so a restart, a missed update or a conflicting automation never makes
the plan send a command the charger has already obeyed.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from . import planner
from .const import (
    CHARGING_ENABLED_STATES,
    ENERGY_DONE_KWH,
    PHASE_ATTENTION,
    PHASE_CANCELLED,
    PHASE_CHARGING,
    PHASE_COMPLETE,
    PHASE_DELAYED,
    PHASE_EXPIRED,
    PHASE_HOLDING,
    PHASE_OVERRIDE,
    PHASE_SCHEDULED,
    PHASE_UNLIKELY,
    PHASE_WAITING_FOR_POWER,
    STATUS_DELAY_WAITING,
    STATUS_ERROR,
    STATUS_EV_WAITING,
    STATUS_FINISHED,
    STATUS_LB_WAITING,
    STATUS_UNPLUGGED,
    TARGET_ADD_KWH,
    TARGET_REACH_PERCENT,
    TERMINAL_PHASES,
)

FRESH_FOR = timedelta(minutes=10)
CONFIRM_WITHIN = timedelta(seconds=150)
EXPIRY_GRACE = timedelta(minutes=15)
MINIMUM_RATE_KW = 0.5
MAX_COMMANDS_PER_HOUR = 6


def _iso(moment: datetime | None) -> str | None:
    return moment.astimezone(timezone.utc).isoformat() if moment else None


def _parse(text: str | None) -> datetime | None:
    return datetime.fromisoformat(text) if text else None


@dataclass
class ChargerSnapshot:
    """What Home Assistant knows about the charger right now."""

    status: str | None = None
    power_kw: float | None = None
    energy_kwh: float | None = None
    timestamp: datetime | None = None

    @property
    def available(self) -> bool:
        return self.status not in (None, "unavailable", "unknown")

    def is_fresh(self, now: datetime) -> bool:
        return self.timestamp is not None and now - self.timestamp <= FRESH_FOR

    @property
    def charging_enabled(self) -> bool:
        return self.status in CHARGING_ENABLED_STATES


@dataclass
class BatteryReading:
    """A battery sensor Home Assistant maintains on its own."""

    percent: float | None = None
    timestamp: datetime | None = None

    def is_fresh(self, now: datetime, max_age: timedelta = timedelta(minutes=30)) -> bool:
        return self.percent is not None and self.timestamp is not None and now - self.timestamp <= max_age


@dataclass
class Plan:
    plan_id: str
    charger_id: str
    target_type: str
    target_value: float
    deadline: datetime
    time_zone: str
    usable_capacity_kwh: float
    loss_factor: float
    rate_hint_kw: float
    created_at: datetime
    hold: bool = False
    override: bool = False
    delivered_kwh: float = 0.0
    last_energy: float | None = None
    anchor_remaining: float | None = None
    anchor_delivered: float = 0.0
    rate_kw: float | None = None
    phase: str = PHASE_SCHEDULED
    warnings: list[str] = field(default_factory=list)
    windows: list[dict[str, Any]] = field(default_factory=list)
    remaining_kwh: float | None = None
    expected_finish: datetime | None = None
    estimated_cost: float | None = None
    last_command: dict[str, Any] | None = None
    commands: list[str] = field(default_factory=list)
    message: str | None = None
    updated_at: datetime | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "plan_id": self.plan_id, "charger_id": self.charger_id, "target_type": self.target_type,
            "target_value": self.target_value, "deadline": _iso(self.deadline), "time_zone": self.time_zone,
            "usable_capacity_kwh": self.usable_capacity_kwh, "loss_factor": self.loss_factor,
            "rate_hint_kw": self.rate_hint_kw, "created_at": _iso(self.created_at), "hold": self.hold,
            "override": self.override, "delivered_kwh": self.delivered_kwh, "last_energy": self.last_energy,
            "anchor_remaining": self.anchor_remaining, "anchor_delivered": self.anchor_delivered,
            "rate_kw": self.rate_kw, "phase": self.phase, "warnings": self.warnings, "windows": self.windows,
            "remaining_kwh": self.remaining_kwh, "expected_finish": _iso(self.expected_finish),
            "estimated_cost": self.estimated_cost, "last_command": self.last_command,
            "commands": self.commands, "message": self.message, "updated_at": _iso(self.updated_at),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Plan":
        return cls(
            plan_id=data["plan_id"], charger_id=data["charger_id"], target_type=data["target_type"],
            target_value=float(data["target_value"]), deadline=_parse(data["deadline"]),  # type: ignore[arg-type]
            time_zone=data.get("time_zone", "UTC"), usable_capacity_kwh=float(data.get("usable_capacity_kwh", 0)),
            loss_factor=float(data.get("loss_factor", 1.1)), rate_hint_kw=float(data.get("rate_hint_kw", 7.4)),
            created_at=_parse(data["created_at"]),  # type: ignore[arg-type]
            hold=bool(data.get("hold", False)), override=bool(data.get("override", False)),
            delivered_kwh=float(data.get("delivered_kwh", 0.0)), last_energy=data.get("last_energy"),
            anchor_remaining=data.get("anchor_remaining"), anchor_delivered=float(data.get("anchor_delivered", 0.0)),
            rate_kw=data.get("rate_kw"), phase=data.get("phase", PHASE_SCHEDULED),
            warnings=list(data.get("warnings", [])), windows=list(data.get("windows", [])),
            remaining_kwh=data.get("remaining_kwh"), expected_finish=_parse(data.get("expected_finish")),
            estimated_cost=data.get("estimated_cost"), last_command=data.get("last_command"),
            commands=list(data.get("commands", [])), message=data.get("message"),
            updated_at=_parse(data.get("updated_at")),
        )

    def attributes(self, currency: str | None, price_source: str | None) -> dict[str, Any]:
        """The plan status sensor's attributes. Hisingen reads exactly these."""
        return {
            "plan_id": self.plan_id, "charger_id": self.charger_id,
            "target": {"type": self.target_type, "value": self.target_value},
            "deadline": _iso(self.deadline), "time_zone": self.time_zone, "windows": self.windows,
            "delivered_kwh": round(self.delivered_kwh, 3),
            "remaining_kwh": None if self.remaining_kwh is None else round(self.remaining_kwh, 3),
            "rate_kw": None if self.rate_kw is None else round(self.rate_kw, 2),
            "expected_finish": _iso(self.expected_finish),
            "estimated_cost": None if self.estimated_cost is None else round(self.estimated_cost, 2),
            "currency": currency, "price_source": price_source, "hold": self.hold, "override": self.override,
            "warnings": self.warnings, "message": self.message, "updated_at": _iso(self.updated_at),
        }


@dataclass
class StepResult:
    command: str | None = None  # "turn_on" or "turn_off"
    changed: bool = False


def median_rate(rates: list[float]) -> float | None:
    usable = [rate for rate in rates[-5:] if rate >= MINIMUM_RATE_KW]
    return statistics.median(usable) if usable else None


def _update_delivered(plan: Plan, snapshot: ChargerSnapshot) -> None:
    """Add what the session-energy counter rose by since the last reading. A fall is a reset."""
    if snapshot.energy_kwh is None:
        return
    if plan.last_energy is None:
        plan.last_energy = snapshot.energy_kwh
        return
    if snapshot.energy_kwh >= plan.last_energy:
        plan.delivered_kwh += snapshot.energy_kwh - plan.last_energy
    else:
        plan.delivered_kwh += snapshot.energy_kwh
    plan.last_energy = snapshot.energy_kwh


def _remaining(plan: Plan, battery: BatteryReading, now: datetime, warnings: list[str]) -> float:
    if plan.target_type == TARGET_ADD_KWH:
        return max(0.0, plan.target_value - plan.delivered_kwh)
    # Reach a percentage. Home Assistant's own battery sensor is the truth while it is fresh; when it
    # goes quiet the last good figure is carried forward by what the charger has delivered since.
    if battery.is_fresh(now) and battery.percent is not None:
        remaining = max(0.0, (plan.target_value - battery.percent) / 100 * plan.usable_capacity_kwh * plan.loss_factor)
        plan.anchor_remaining = remaining
        plan.anchor_delivered = plan.delivered_kwh
        return remaining
    warnings.append("battery_sensor_stale")
    if plan.anchor_remaining is None:
        return max(0.0, (plan.target_value / 100) * plan.usable_capacity_kwh * plan.loss_factor)
    return max(0.0, plan.anchor_remaining - (plan.delivered_kwh - plan.anchor_delivered))


def _rate(plan: Plan, snapshot: ChargerSnapshot, history: list[float], now: datetime, warnings: list[str]) -> float:
    base = median_rate(history) or max(plan.rate_hint_kw, MINIMUM_RATE_KW)
    live = (
        snapshot.power_kw
        if snapshot.status == "charging" and snapshot.is_fresh(now) and (snapshot.power_kw or 0) >= MINIMUM_RATE_KW
        else None
    )
    if plan.rate_kw is None:
        plan.rate_kw = base
    elif live is not None:
        plan.rate_kw = 0.7 * plan.rate_kw + 0.3 * live
    if live is not None and live < 0.8 * base:
        warnings.append("rate_below_plan")
    return max(plan.rate_kw or base, MINIMUM_RATE_KW)


def _command_allowed(plan: Plan, kind: str, now: datetime) -> bool:
    """Back off from a command the charger has not obeyed, and cap how many go out in an hour."""
    recent = [c for c in plan.commands if (_parse(c) or now) > now - timedelta(hours=1)]
    plan.commands = recent
    if len(recent) >= MAX_COMMANDS_PER_HOUR:
        return False
    last = plan.last_command
    if last and last.get("kind") == kind and not last.get("confirmed_at"):
        at = _parse(last["at"]) or now
        wait = timedelta(seconds=150 * 2 ** min(int(last.get("attempts", 1)) - 1, 4))
        return now - at >= wait
    return True


def _confirm_last_command(plan: Plan, snapshot: ChargerSnapshot) -> None:
    last = plan.last_command
    if not last or last.get("confirmed_at") or snapshot.timestamp is None:
        return
    at = _parse(last["at"])
    if at is None or snapshot.timestamp < at:
        return
    obeyed = snapshot.charging_enabled if last["kind"] == "turn_on" else (snapshot.available and not snapshot.charging_enabled)
    if obeyed:
        last["confirmed_at"] = _iso(snapshot.timestamp)


def step(
    plan: Plan,
    snapshot: ChargerSnapshot,
    battery: BatteryReading,
    slots: list[planner.PriceSlot],
    now: datetime,
    history_rates: list[float] | None = None,
) -> StepResult:
    """Advance the plan by one tick. Returns the command to send, if any."""
    result = StepResult()
    before = (plan.phase, tuple(plan.warnings), plan.delivered_kwh, plan.remaining_kwh)
    warnings: list[str] = []
    if plan.phase in TERMINAL_PHASES:
        return result

    _update_delivered(plan, snapshot)
    _confirm_last_command(plan, snapshot)
    remaining = _remaining(plan, battery, now, warnings)
    plan.remaining_kwh = remaining
    plan.updated_at = now

    def finish(phase: str, command_off: bool = False) -> StepResult:
        plan.phase = phase
        plan.warnings = warnings
        plan.windows = []
        plan.override = False
        if command_off and snapshot.charging_enabled and _command_allowed(plan, "turn_off", now):
            _record(plan, "turn_off", now)
            result.command = "turn_off"
        result.changed = True
        return result

    if remaining <= ENERGY_DONE_KWH:
        return finish(PHASE_COMPLETE, command_off=True)
    stopped_by_us = bool(plan.last_command) and plan.last_command.get("kind") == "turn_off"  # type: ignore[union-attr]
    if snapshot.status == STATUS_FINISHED and remaining > 0.5 and not stopped_by_us:
        # The car stopped at its own battery limit, which is the ceiling a plan never exceeds. When the
        # last thing this plan did was stop the charger, "finished" may just be how it reports that
        # stop, so it is not read as the car being full.
        warnings.append("car_limit_reached")
        return finish(PHASE_COMPLETE)
    if now >= plan.deadline + EXPIRY_GRACE:
        return finish(PHASE_EXPIRED)

    rate = _rate(plan, snapshot, history_rates or [], now, warnings)

    previous_windows = list(plan.windows)
    window_plan = _windows(plan, slots, now, remaining, rate, warnings)
    in_window = any(
        _parse(window["start"]) <= now < _parse(window["end"])  # type: ignore[operator]
        for window in plan.windows
    )

    # Charger readings that cannot be trusted: say so and send nothing. The windows above are still
    # worked out, so a preview and the status sensor stay useful while the charger is offline.
    if not snapshot.available or not snapshot.is_fresh(now):
        warnings.append("charger_unavailable")
        plan.phase = PHASE_ATTENTION
        plan.message = None
        plan.warnings = warnings
        return _done(plan, before, result)

    if plan.hold:
        desired = "off"
        phase = PHASE_HOLDING
    elif plan.override:
        desired = "on"
        phase = PHASE_OVERRIDE
    elif not window_plan.feasible:
        warnings.append("deadline_unlikely")
        desired = "on"
        phase = PHASE_UNLIKELY
    else:
        desired = "on" if in_window else "off"
        phase = PHASE_SCHEDULED

    if snapshot.status == STATUS_UNPLUGGED:
        # Nothing to command; the plan waits for the cable.
        plan.phase = PHASE_HOLDING if plan.hold else (PHASE_UNLIKELY if phase == PHASE_UNLIKELY else PHASE_SCHEDULED)
        plan.warnings = warnings
        return _done(plan, before, result)
    if snapshot.status == STATUS_ERROR:
        plan.phase = PHASE_ATTENTION
        warnings.append("charger_unavailable")
        plan.warnings = warnings
        return _done(plan, before, result)

    # Do not stop a charge that is running inside the window it was planned for just because a
    # fresh price list moved the cheapest hours: finish the window, then follow the new plan.
    if desired == "off" and phase == PHASE_SCHEDULED and snapshot.charging_enabled and any(
        _parse(window["start"]) <= now < _parse(window["end"])  # type: ignore[operator]
        for window in previous_windows
    ):
        desired = "on"

    # Judged on the command already out, before a retry replaces it: one still unobeyed after the
    # confirmation window, or already retried, is reported as unconfirmed.
    previous = plan.last_command
    unconfirmed = bool(previous) and not previous.get("confirmed_at") and (  # type: ignore[union-attr]
        (_parse(previous["at"]) or now) + CONFIRM_WITHIN <= now  # type: ignore[index]
        or int(previous.get("attempts", 1)) >= 2  # type: ignore[union-attr]
    )

    if desired == "on":
        if snapshot.charging_enabled:
            if snapshot.status == STATUS_LB_WAITING:
                phase = PHASE_WAITING_FOR_POWER if phase == PHASE_SCHEDULED else phase
                warnings.append("waiting_for_power")
            elif snapshot.status == STATUS_EV_WAITING:
                warnings.append("waiting_for_vehicle")
            if phase == PHASE_SCHEDULED:
                phase = PHASE_CHARGING
        else:
            if snapshot.status == STATUS_DELAY_WAITING:
                warnings.append("delayed_start_active")
                if phase == PHASE_SCHEDULED:
                    phase = PHASE_DELAYED
            if _command_allowed(plan, "turn_on", now):
                _record(plan, "turn_on", now)
                result.command = "turn_on"
    else:
        if snapshot.charging_enabled and _command_allowed(plan, "turn_off", now):
            _record(plan, "turn_off", now)
            result.command = "turn_off"

    if unconfirmed:
        warnings.append("command_unconfirmed")

    plan.phase = phase
    plan.warnings = list(dict.fromkeys(warnings))
    return _done(plan, before, result)


def _done(plan: Plan, before: tuple[Any, ...], result: StepResult) -> StepResult:
    plan.warnings = list(dict.fromkeys(plan.warnings))
    result.changed = result.changed or before != (plan.phase, tuple(plan.warnings), plan.delivered_kwh, plan.remaining_kwh)
    return result


def _record(plan: Plan, kind: str, now: datetime) -> None:
    previous = plan.last_command
    attempts = 1
    if previous and previous.get("kind") == kind and not previous.get("confirmed_at"):
        attempts = int(previous.get("attempts", 1)) + 1
    plan.last_command = {"kind": kind, "at": _iso(now), "attempts": attempts, "confirmed_at": None}
    plan.commands.append(_iso(now) or "")


def _windows(plan: Plan, slots: list[planner.PriceSlot], now: datetime, remaining: float, rate: float,
             warnings: list[str]) -> planner.WindowPlan:
    if not slots:
        # No prices at all: charge as soon as possible so the deadline is still met.
        warnings.append("prices_missing")
        seconds = remaining / rate * 3600
        end = min(plan.deadline, now + timedelta(seconds=seconds))
        feasible = now + timedelta(seconds=seconds) <= plan.deadline
        plan.windows = [{"start": _iso(now), "end": _iso(end), "avg_price": None}]
        plan.expected_finish = end
        plan.estimated_cost = None
        shortfall = 0.0 if feasible else remaining - (plan.deadline - now).total_seconds() / 3600 * rate
        return planner.WindowPlan((), feasible, seconds / 3600, seconds / 3600, shortfall, 0.0, end, True)
    covered = planner.fill_missing(slots, plan.deadline)
    if any(slot.estimated for slot in covered):
        warnings.append("prices_missing")
    window_plan = planner.plan_windows(covered, now, plan.deadline, remaining, rate)
    plan.windows = [
        {"start": _iso(window.start), "end": _iso(window.end), "avg_price": round(window.avg_price, 4),
         "estimated": window.estimated}
        for window in window_plan.windows
    ]
    plan.expected_finish = window_plan.expected_finish
    plan.estimated_cost = window_plan.cost
    return window_plan
