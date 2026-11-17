"""Shared builders for the component tests. No Home Assistant is needed to run any of them."""
from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from custom_components.hisingen_home_charging import engine, planner  # noqa: E402
from custom_components.hisingen_home_charging.const import TARGET_ADD_KWH  # noqa: E402

T0 = datetime(2026, 11, 16, 18, 0, tzinfo=timezone.utc)


def at(minutes: float) -> datetime:
    return T0 + timedelta(minutes=minutes)


def quarter_slots(prices: list[float], start_minute: float = 0) -> list[planner.PriceSlot]:
    return [
        planner.PriceSlot(at(start_minute + 15 * i), at(start_minute + 15 * (i + 1)), price)
        for i, price in enumerate(prices)
    ]


def make_plan(target: float = 18.0, deadline_minutes: float = 600, kind: str = TARGET_ADD_KWH,
              rate: float = 7.2, capacity: float = 75.0) -> engine.Plan:
    return engine.Plan(
        plan_id="plan-1", charger_id="NX1", target_type=kind, target_value=target, deadline=at(deadline_minutes),
        time_zone="Europe/Stockholm", usable_capacity_kwh=capacity, loss_factor=1.1, rate_hint_kw=rate, created_at=at(0),
    )


def snapshot(status: str = "connected", power: float | None = 0.0, energy: float | None = 0.0,
             minutes: float = 0.0) -> engine.ChargerSnapshot:
    return engine.ChargerSnapshot(status=status, power_kw=power, energy_kwh=energy, timestamp=at(minutes))


NO_BATTERY = engine.BatteryReading()
