"""Chooses when to charge from published import prices.

Pure functions over price slots. Prices come from Tibber in 15-minute slots; any slot length
works because every window is accumulated in seconds, not in slot counts.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

# A contiguous block is preferred over cheaper scattered slots when it costs no more than this
# much extra: five percent, or 25 currency units' worth of hundredths, whichever is larger.
CONTIGUITY_TOLERANCE_REL = 0.05
CONTIGUITY_TOLERANCE_ABS = 0.25
DEFAULT_SLOT = timedelta(minutes=15)
_EPSILON = 1e-6


@dataclass(frozen=True)
class PriceSlot:
    start: datetime
    end: datetime
    price: float
    estimated: bool = False

    @property
    def seconds(self) -> float:
        return (self.end - self.start).total_seconds()


@dataclass(frozen=True)
class Window:
    start: datetime
    end: datetime
    avg_price: float
    estimated: bool = False

    @property
    def seconds(self) -> float:
        return (self.end - self.start).total_seconds()


@dataclass(frozen=True)
class WindowPlan:
    windows: tuple[Window, ...]
    feasible: bool
    needed_hours: float
    planned_hours: float
    shortfall_kwh: float
    cost: float
    expected_finish: datetime | None
    contiguous: bool


def slots_from_points(points: list[tuple[datetime, float]]) -> list[PriceSlot]:
    """Turn (start, price) points into slots that end where the next begins."""
    ordered = sorted(points, key=lambda point: point[0])
    slots: list[PriceSlot] = []
    step = DEFAULT_SLOT
    for index, (start, price) in enumerate(ordered):
        if index + 1 < len(ordered):
            gap = ordered[index + 1][0] - start
            if gap > timedelta(0):
                step = gap
            else:
                continue
        slots.append(PriceSlot(start, start + step, price))
    return slots


def fill_missing(slots: list[PriceSlot], until: datetime) -> list[PriceSlot]:
    """Extend past the last published price with slots at the average known price.

    Tomorrow's prices appear in the afternoon. Until then a deadline tomorrow morning reaches past
    the data, and refusing to plan would be wrong; the extension is marked as an estimate and is
    replaced the next minute the real prices exist.
    """
    if not slots:
        return []
    ordered = sorted(slots, key=lambda slot: slot.start)
    average = sum(slot.price * slot.seconds for slot in ordered) / max(
        sum(slot.seconds for slot in ordered), _EPSILON
    )
    filled = list(ordered)
    cursor = ordered[-1].end
    while cursor < until:
        filled.append(PriceSlot(cursor, cursor + DEFAULT_SLOT, average, estimated=True))
        cursor += DEFAULT_SLOT
    return filled


def clip(slots: list[PriceSlot], start: datetime, end: datetime) -> list[PriceSlot]:
    """The parts of the slots that lie inside [start, end)."""
    clipped: list[PriceSlot] = []
    for slot in sorted(slots, key=lambda item: item.start):
        low, high = max(slot.start, start), min(slot.end, end)
        if high > low:
            clipped.append(PriceSlot(low, high, slot.price, slot.estimated))
    return clipped


def _merge(pieces: list[PriceSlot]) -> list[Window]:
    merged: list[Window] = []
    for piece in sorted(pieces, key=lambda item: item.start):
        if merged and abs((piece.start - merged[-1].end).total_seconds()) < 1:
            last = merged[-1]
            seconds = last.seconds + piece.seconds
            average = (last.avg_price * last.seconds + piece.price * piece.seconds) / seconds
            merged[-1] = Window(last.start, piece.end, average, last.estimated or piece.estimated)
        else:
            merged.append(Window(piece.start, piece.end, piece.price, piece.estimated))
    return merged


def _chains(slots: list[PriceSlot]) -> list[list[PriceSlot]]:
    chains: list[list[PriceSlot]] = []
    for slot in slots:
        if chains and abs((slot.start - chains[-1][-1].end).total_seconds()) < 1:
            chains[-1].append(slot)
        else:
            chains.append([slot])
    return chains


def _integrate(chain: list[PriceSlot], start: datetime, seconds: float) -> tuple[float, list[PriceSlot]]:
    """Price-seconds of a window of `seconds` starting at `start`, and the pieces it covers."""
    end = start + timedelta(seconds=seconds)
    pieces = clip(chain, start, end)
    return sum(piece.price * piece.seconds for piece in pieces), pieces


def _best_contiguous(slots: list[PriceSlot], needed_seconds: float) -> list[PriceSlot] | None:
    best_cost: float | None = None
    best_pieces: list[PriceSlot] | None = None
    for chain in _chains(slots):
        chain_start, chain_end = chain[0].start, chain[-1].end
        if (chain_end - chain_start).total_seconds() + _EPSILON < needed_seconds:
            continue
        candidates = {slot.start for slot in chain}
        candidates |= {slot.end - timedelta(seconds=needed_seconds) for slot in chain}
        for start in sorted(candidates):
            if start < chain_start or start + timedelta(seconds=needed_seconds) > chain_end + timedelta(seconds=_EPSILON):
                continue
            cost, pieces = _integrate(chain, start, needed_seconds)
            if best_cost is None or cost < best_cost - _EPSILON:
                best_cost, best_pieces = cost, pieces
    return best_pieces


def _cheapest_scattered(slots: list[PriceSlot], needed_seconds: float) -> list[PriceSlot]:
    chosen: list[PriceSlot] = []
    remaining = needed_seconds
    for slot in sorted(slots, key=lambda item: (item.price, item.start)):
        if remaining <= _EPSILON:
            break
        take = min(slot.seconds, remaining)
        chosen.append(PriceSlot(slot.start, slot.start + timedelta(seconds=take), slot.price, slot.estimated))
        remaining -= take
    return chosen


def _cost(pieces: list[PriceSlot], rate_kw: float) -> float:
    return sum(piece.price * piece.seconds / 3600 * rate_kw for piece in pieces)


def plan_windows(
    slots: list[PriceSlot],
    now: datetime,
    deadline: datetime,
    needed_kwh: float,
    rate_kw: float,
) -> WindowPlan:
    """Pick the cheapest windows that deliver `needed_kwh` by `deadline` at `rate_kw`.

    Prefers one contiguous block. When the deadline cannot be met at this rate, every slot before
    it is used and the energy still missing is reported.
    """
    if needed_kwh <= _EPSILON or rate_kw <= _EPSILON:
        return WindowPlan((), True, 0.0, 0.0, 0.0, 0.0, None, True)
    available = clip(slots, now, deadline)
    needed_seconds = needed_kwh / rate_kw * 3600
    total_seconds = sum(slot.seconds for slot in available)
    needed_hours = needed_seconds / 3600

    if total_seconds + _EPSILON < needed_seconds:
        windows = _merge(available)
        shortfall = (needed_seconds - total_seconds) / 3600 * rate_kw
        return WindowPlan(
            tuple(windows), False, needed_hours, total_seconds / 3600, shortfall,
            _cost(available, rate_kw), windows[-1].end if windows else None, len(windows) <= 1,
        )

    scattered = _cheapest_scattered(available, needed_seconds)
    contiguous = _best_contiguous(available, needed_seconds)
    chosen, is_contiguous = scattered, False
    if contiguous is not None:
        extra = _cost(contiguous, rate_kw) - _cost(scattered, rate_kw)
        allowance = max(CONTIGUITY_TOLERANCE_REL * _cost(scattered, rate_kw), CONTIGUITY_TOLERANCE_ABS)
        if extra <= allowance + _EPSILON:
            chosen, is_contiguous = contiguous, True
    windows = _merge(chosen)
    return WindowPlan(
        tuple(windows), True, needed_hours, needed_hours, 0.0, _cost(chosen, rate_kw),
        windows[-1].end if windows else None, is_contiguous and len(windows) == 1,
    )
