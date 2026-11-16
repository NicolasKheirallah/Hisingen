"""Hisingen Home Charging.

Runs the charging plan Hisingen submits for a home charger, and records the charger's finished
sessions, so both carry on when the Mac sleeps or Hisingen is closed. Home Assistant glue lives in
``runtime``; the planning, plan engine and session recorder are plain Python with no Home
Assistant imports, so they run under the standard library's unittest.
"""
from __future__ import annotations

from typing import Any

from .const import DOMAIN


async def async_setup(hass: Any, config: dict[str, Any]) -> bool:
    """Set the component up from ``hisingen_home_charging:`` in configuration.yaml."""
    from .runtime import async_setup_runtime

    return await async_setup_runtime(hass, config)
