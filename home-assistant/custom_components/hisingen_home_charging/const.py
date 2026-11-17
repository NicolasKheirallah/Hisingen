"""Shared names for the Hisingen Home Charging component."""

DOMAIN = "hisingen_home_charging"
STORE_KEY = DOMAIN
STORE_VERSION = 1

# Charger states of the Home Assistant NexBlue integration (enum sensor options).
STATUS_UNPLUGGED = "idle"
STATUS_CONNECTED = "connected"
STATUS_CHARGING = "charging"
STATUS_FINISHED = "finished"
STATUS_ERROR = "error"
STATUS_LB_WAITING = "lb_waiting"
STATUS_DELAY_WAITING = "delay_waiting"
STATUS_EV_WAITING = "ev_waiting"

# The charging switch reads "on" for exactly these three, so they are what a start command is
# confirmed by and what a pause command must leave.
CHARGING_ENABLED_STATES = frozenset({STATUS_CHARGING, STATUS_LB_WAITING, STATUS_EV_WAITING})

# Plan phases, as the plan status sensor reports them. Hisingen reads the same words.
PHASE_IDLE = "idle"
PHASE_SCHEDULED = "scheduled"
PHASE_CHARGING = "charging"
PHASE_WAITING_FOR_POWER = "waiting_for_power"
PHASE_DELAYED = "delayed"
PHASE_HOLDING = "holding"
PHASE_OVERRIDE = "override"
PHASE_COMPLETE = "complete"
PHASE_UNLIKELY = "unlikely"
PHASE_ATTENTION = "attention"
PHASE_CANCELLED = "cancelled"
PHASE_EXPIRED = "expired"

TERMINAL_PHASES = frozenset({PHASE_IDLE, PHASE_COMPLETE, PHASE_CANCELLED, PHASE_EXPIRED})

TARGET_ADD_KWH = "add_kwh"
TARGET_REACH_PERCENT = "reach_percent"

ENERGY_DONE_KWH = 0.05
