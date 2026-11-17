"""Records a charger's finished sessions as they happen.

The NexBlue integration keeps no session list, and Home Assistant's recorder prunes history after
ten days by default. This module follows the charger's session-energy counter live and keeps each
finished session, with its energy per 15-minute interval, so Hisingen can import it whenever it
next connects, however long that is.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from .const import CHARGING_ENABLED_STATES, STATUS_UNPLUGGED

RESET_THRESHOLD_KWH = 0.05
# Float noise from a sensor is not a rise; a milliwatt-hour is far below any real reading step.
RISE_EPSILON_KWH = 1e-6
MINIMUM_SESSION_KWH = 0.1
SETTLE_AFTER = timedelta(minutes=30)
# A rise across a longer gap says how much arrived, not when; such a session is marked coarse and
# Hisingen prices its total instead of pretending to know the profile.
COARSE_GAP = timedelta(minutes=20)
BUCKET = timedelta(minutes=15)
MAX_KEPT_SESSIONS = 400


def _bucket_start(moment: datetime) -> datetime:
    utc = moment.astimezone(timezone.utc)
    minutes = utc.minute - utc.minute % 15
    return utc.replace(minute=minutes, second=0, microsecond=0)


def session_id(charger_id: str, started_at: datetime) -> str:
    """Stable across restarts: the same start always gives the same id."""
    digest = hashlib.sha1(f"{charger_id}:{int(started_at.timestamp())}".encode()).hexdigest()
    return digest[:12]


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat()


def _parse(text: str) -> datetime:
    return datetime.fromisoformat(text)


@dataclass
class _Run:
    started_at: datetime
    last_rise: datetime
    energy: float = 0.0
    peak_kw: float = 0.0
    coarse: bool = False
    soc_start: float | None = None
    buckets: dict[str, float] = field(default_factory=dict)

    def add(self, start: datetime, end: datetime, kwh: float) -> None:
        """Spread `kwh` over [start, end) into 15-minute buckets in proportion to time."""
        total = (end - start).total_seconds()
        if total <= 0 or kwh <= 0:
            return
        cursor = start
        while cursor < end:
            bucket = _bucket_start(cursor)
            bucket_end = bucket + BUCKET
            piece_end = min(end, bucket_end)
            share = kwh * (piece_end - cursor).total_seconds() / total
            key = _iso(bucket)
            self.buckets[key] = self.buckets.get(key, 0.0) + share
            cursor = piece_end

    def to_dict(self) -> dict[str, Any]:
        return {
            "started_at": _iso(self.started_at), "last_rise": _iso(self.last_rise), "energy": self.energy,
            "peak_kw": self.peak_kw, "coarse": self.coarse, "soc_start": self.soc_start, "buckets": self.buckets,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "_Run":
        return cls(
            started_at=_parse(data["started_at"]), last_rise=_parse(data["last_rise"]),
            energy=float(data.get("energy", 0.0)), peak_kw=float(data.get("peak_kw", 0.0)),
            coarse=bool(data.get("coarse", False)), soc_start=data.get("soc_start"),
            buckets=dict(data.get("buckets", {})),
        )


class SessionRecorder:
    """One recorder per charger. Feed it every reading; it returns sessions as they finish."""

    def __init__(self, charger_id: str) -> None:
        self.charger_id = charger_id
        self.completed: list[dict[str, Any]] = []
        self._run: _Run | None = None
        self._last_energy: float | None = None
        self._last_time: datetime | None = None
        self._last_status: str | None = None
        self._last_soc: float | None = None

    # -- persistence ---------------------------------------------------------------------------

    def to_dict(self) -> dict[str, Any]:
        return {
            "completed": self.completed,
            "run": self._run.to_dict() if self._run else None,
            "last_energy": self._last_energy,
            "last_time": _iso(self._last_time) if self._last_time else None,
            "last_status": self._last_status,
            "last_soc": self._last_soc,
        }

    @classmethod
    def from_dict(cls, charger_id: str, data: dict[str, Any]) -> "SessionRecorder":
        recorder = cls(charger_id)
        recorder.completed = list(data.get("completed", []))
        if data.get("run"):
            recorder._run = _Run.from_dict(data["run"])
        recorder._last_energy = data.get("last_energy")
        recorder._last_time = _parse(data["last_time"]) if data.get("last_time") else None
        recorder._last_status = data.get("last_status")
        recorder._last_soc = data.get("last_soc")
        return recorder

    # -- observation ---------------------------------------------------------------------------

    def observe(
        self,
        now: datetime,
        status: str | None,
        energy_kwh: float | None,
        power_kw: float | None = None,
        soc_percent: float | None = None,
    ) -> dict[str, Any] | None:
        """Take one reading. Returns a session if this reading finished one."""
        finished: dict[str, Any] | None = None

        # The cable coming out closes a session whether or not the counter reset.
        if status == STATUS_UNPLUGGED and self._last_status not in (None, STATUS_UNPLUGGED):
            finished = self._finalize(soc_end=self._last_soc)
        if status is not None:
            self._last_status = status

        if power_kw is not None and self._run is not None:
            self._run.peak_kw = max(self._run.peak_kw, power_kw)

        # A reading stamped no later than the last one adds nothing and must not move the clock back.
        if energy_kwh is not None and (self._last_time is None or now >= self._last_time):
            if self._last_energy is not None and self._last_time is not None:
                if energy_kwh < self._last_energy - RESET_THRESHOLD_KWH:
                    finished = self._finalize(soc_end=self._last_soc) or finished
                elif energy_kwh > self._last_energy + RISE_EPSILON_KWH and now > self._last_time:
                    self._rise(self._last_time, now, energy_kwh - self._last_energy)
            self._last_energy = energy_kwh
            self._last_time = now

        if soc_percent is not None:
            self._last_soc = soc_percent
        return finished

    def _rise(self, start: datetime, end: datetime, delta: float) -> None:
        if self._run is None:
            self._run = _Run(started_at=start, last_rise=end, soc_start=self._last_soc)
        run = self._run
        run.energy += delta
        run.last_rise = end
        if end - start > COARSE_GAP:
            run.coarse = True
        run.add(start, end, delta)

    def tick(self, now: datetime, status: str | None) -> dict[str, Any] | None:
        """Finish a session that has been quiet long enough that it is over."""
        if self._run is None:
            return None
        if status in CHARGING_ENABLED_STATES:
            return None
        if now - self._run.last_rise >= SETTLE_AFTER:
            return self._finalize(soc_end=self._last_soc)
        return None

    def _finalize(self, soc_end: float | None) -> dict[str, Any] | None:
        run, self._run = self._run, None
        if run is None or run.energy < MINIMUM_SESSION_KWH:
            return None
        intervals = [
            {"start": key, "end": _iso(_parse(key) + BUCKET), "kwh": round(value, 4)}
            for key, value in sorted(run.buckets.items())
            if value > 0
        ]
        record: dict[str, Any] = {
            "id": session_id(self.charger_id, run.started_at),
            "started_at": _iso(run.started_at),
            "ended_at": _iso(run.last_rise),
            "energy_kwh": round(run.energy, 4),
            "peak_power_kw": round(run.peak_kw, 3) if run.peak_kw else None,
            "coarse": run.coarse,
            "intervals": [] if run.coarse else intervals,
            "vehicle_start_percent": run.soc_start,
            "vehicle_end_percent": soc_end,
        }
        self.completed.append(record)
        self.completed = self.completed[-MAX_KEPT_SESSIONS:]
        return record

    # -- reads ---------------------------------------------------------------------------------

    def sessions_since(self, since: datetime | None) -> list[dict[str, Any]]:
        if since is None:
            return list(self.completed)
        return [item for item in self.completed if _parse(item["ended_at"]) >= since]


def session_average_power_kw(record: dict[str, Any]) -> float | None:
    """Average power over the time the session was actually charging, for planning a future rate."""
    intervals = record.get("intervals") or []
    active_hours = 0.0
    active_kwh = 0.0
    for interval in intervals:
        hours = (_parse(interval["end"]) - _parse(interval["start"])).total_seconds() / 3600
        if hours > 0 and interval["kwh"] / hours >= 0.5:
            active_hours += hours
            active_kwh += interval["kwh"]
    if active_hours <= 0:
        return None
    return active_kwh / active_hours
