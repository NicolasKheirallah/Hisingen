import unittest

from tests.helpers import NO_BATTERY, at, make_plan, quarter_slots, snapshot

from custom_components.hisingen_home_charging import engine
from custom_components.hisingen_home_charging.const import (
    PHASE_ATTENTION,
    PHASE_CHARGING,
    PHASE_COMPLETE,
    PHASE_DELAYED,
    PHASE_EXPIRED,
    PHASE_HOLDING,
    PHASE_OVERRIDE,
    PHASE_SCHEDULED,
    PHASE_UNLIKELY,
    PHASE_WAITING_FOR_POWER,
    TARGET_REACH_PERCENT,
)

CHEAP_NOW = quarter_slots([0.2] * 12 + [2.0] * 28)      # 3 h cheap from the start, 10 h in total
CHEAP_LATER = quarter_slots([2.0] * 8 + [0.2] * 12 + [2.0] * 20)   # cheap from 02:00 to 05:00


def step(plan, snap, slots, minutes, battery=NO_BATTERY, rates=None):
    return engine.step(plan, snap, battery, slots, at(minutes), rates)


class StartStopTests(unittest.TestCase):
    def test_starts_the_charger_inside_a_planned_window(self):
        plan = make_plan()
        result = step(plan, snapshot("connected"), CHEAP_NOW, 0)
        self.assertEqual(result.command, "turn_on")
        self.assertEqual(plan.last_command["kind"], "turn_on")

    def test_waits_outside_the_window_without_a_command(self):
        plan = make_plan()
        result = step(plan, snapshot("connected"), CHEAP_LATER, 0)
        self.assertIsNone(result.command)
        self.assertEqual(plan.phase, PHASE_SCHEDULED)
        self.assertEqual(plan.windows[0]["start"], at(120).isoformat())

    def test_stops_a_charge_that_is_running_outside_the_window(self):
        plan = make_plan()
        result = step(plan, snapshot("charging", power=7.2), CHEAP_LATER, 0)
        self.assertEqual(result.command, "turn_off")

    def test_a_charger_that_already_obeys_gets_no_command(self):
        plan = make_plan()
        result = step(plan, snapshot("charging", power=7.2), CHEAP_NOW, 0)
        self.assertIsNone(result.command)
        self.assertEqual(plan.phase, PHASE_CHARGING)

    def test_an_unplugged_charger_is_not_commanded_and_the_plan_waits(self):
        plan = make_plan()
        result = step(plan, snapshot("idle", power=0), CHEAP_NOW, 0)
        self.assertIsNone(result.command)
        self.assertEqual(plan.phase, PHASE_SCHEDULED)

    def test_a_stale_or_unavailable_charger_is_never_commanded(self):
        plan = make_plan()
        old = snapshot("connected", minutes=-30)
        self.assertIsNone(step(plan, old, CHEAP_NOW, 0).command)
        self.assertEqual(plan.phase, PHASE_ATTENTION)
        self.assertIn("charger_unavailable", plan.warnings)
        self.assertIsNone(step(plan, snapshot("unavailable"), CHEAP_NOW, 1).command)
        # The windows are still worked out, so a preview stays useful while the charger is offline.
        self.assertTrue(plan.windows)

    def test_waiting_for_power_is_reported_not_fought(self):
        plan = make_plan()
        result = step(plan, snapshot("lb_waiting", power=0), CHEAP_NOW, 0)
        self.assertIsNone(result.command)
        self.assertEqual(plan.phase, PHASE_WAITING_FOR_POWER)
        self.assertIn("waiting_for_power", plan.warnings)

    def test_a_delayed_start_on_the_charger_is_surfaced_as_a_conflict(self):
        plan = make_plan()
        result = step(plan, snapshot("delay_waiting", power=0), CHEAP_NOW, 0)
        self.assertEqual(plan.phase, PHASE_DELAYED)
        self.assertIn("delayed_start_active", plan.warnings)
        self.assertEqual(result.command, "turn_on")

    def test_a_running_charge_finishes_its_window_when_prices_move(self):
        plan = make_plan()
        step(plan, snapshot("connected"), CHEAP_NOW, 0)
        # New prices make "now" expensive, but the charger is running inside the window planned for it.
        result = step(plan, snapshot("charging", power=7.2, minutes=1), CHEAP_LATER, 1)
        self.assertIsNone(result.command)


class HoldAndOverrideTests(unittest.TestCase):
    def test_pause_is_a_hold_that_stays_until_resumed_even_across_a_restart(self):
        plan = make_plan()
        plan.hold = True
        self.assertEqual(step(plan, snapshot("charging", power=7.2), CHEAP_NOW, 0).command, "turn_off")
        self.assertEqual(plan.phase, PHASE_HOLDING)
        # The charger obeys; inside a cheap window the plan still sends nothing.
        self.assertIsNone(step(plan, snapshot("connected", power=0, minutes=1), CHEAP_NOW, 1).command)
        restarted = engine.Plan.from_dict(plan.to_dict())
        self.assertTrue(restarted.hold)
        self.assertIsNone(step(restarted, snapshot("connected", power=0, minutes=2), CHEAP_NOW, 2).command)
        self.assertEqual(restarted.phase, PHASE_HOLDING)
        restarted.hold = False
        self.assertEqual(step(restarted, snapshot("connected", power=0, minutes=3), CHEAP_NOW, 3).command, "turn_on")

    def test_charge_now_overrides_the_windows_and_ends_at_the_target(self):
        plan = make_plan(target=18.0)
        plan.override = True
        self.assertEqual(step(plan, snapshot("connected", energy=0.0), CHEAP_LATER, 0).command, "turn_on")
        self.assertEqual(plan.phase, PHASE_OVERRIDE)
        self.assertTrue(plan.override)
        result = step(plan, snapshot("charging", power=7.2, energy=18.2, minutes=150), CHEAP_LATER, 150)
        self.assertEqual(plan.phase, PHASE_COMPLETE)
        self.assertFalse(plan.override)
        self.assertEqual(result.command, "turn_off")


class RestartRecoveryTests(unittest.TestCase):
    def test_after_a_restart_the_actual_charger_state_is_read_before_any_command(self):
        plan = make_plan()
        plan.last_command = {"kind": "turn_on", "at": at(-1).isoformat(), "attempts": 1, "confirmed_at": None}
        restored = engine.Plan.from_dict(plan.to_dict())
        # While Home Assistant was down the charger obeyed. Nothing is sent, and the command is confirmed.
        result = step(restored, snapshot("charging", power=7.2), CHEAP_NOW, 0)
        self.assertIsNone(result.command)
        self.assertIsNotNone(restored.last_command["confirmed_at"])

    def test_a_charger_not_yet_loaded_after_startup_is_not_commanded(self):
        restored = engine.Plan.from_dict(make_plan().to_dict())
        self.assertIsNone(step(restored, engine.ChargerSnapshot(), CHEAP_NOW, 0).command)
        self.assertEqual(restored.phase, PHASE_ATTENTION)
        self.assertEqual(step(restored, snapshot("connected", minutes=1), CHEAP_NOW, 1).command, "turn_on")

    def test_progress_survives_a_restart_without_counting_energy_twice(self):
        plan = make_plan(target=18.0)
        step(plan, snapshot("charging", power=7.2, energy=0.0), CHEAP_NOW, 0)
        step(plan, snapshot("charging", power=7.2, energy=6.0, minutes=50), CHEAP_NOW, 50)
        self.assertAlmostEqual(plan.delivered_kwh, 6.0)
        restored = engine.Plan.from_dict(plan.to_dict())
        step(restored, snapshot("charging", power=7.2, energy=6.0, minutes=51), CHEAP_NOW, 51)
        self.assertAlmostEqual(restored.delivered_kwh, 6.0)
        step(restored, snapshot("charging", power=7.2, energy=7.2, minutes=60), CHEAP_NOW, 60)
        self.assertAlmostEqual(restored.delivered_kwh, 7.2)


class ProgressAndRecalculationTests(unittest.TestCase):
    def test_a_counter_reset_adds_the_new_value_instead_of_subtracting(self):
        plan = make_plan(target=40.0)
        for minute, energy in enumerate([0.0, 5.0, 11.0, 0.5, 4.0]):
            step(plan, snapshot("charging", power=7.2, energy=energy, minutes=minute), CHEAP_NOW, minute)
        self.assertAlmostEqual(plan.delivered_kwh, 15.0)

    def test_slower_charging_than_planned_stretches_the_windows_from_delivered_energy(self):
        plan = make_plan(target=18.0, rate=7.2)
        step(plan, snapshot("charging", power=3.0, energy=0.0), CHEAP_NOW, 0)
        first_hours = sum(engine._parse(w["end"]).timestamp() - engine._parse(w["start"]).timestamp() for w in plan.windows) / 3600
        for minute in range(1, 25):
            step(plan, snapshot("charging", power=3.0, energy=minute * 0.05, minutes=minute), CHEAP_NOW, minute)
        later_hours = sum(engine._parse(w["end"]).timestamp() - engine._parse(w["start"]).timestamp() for w in plan.windows) / 3600
        self.assertLess(plan.rate_kw, 6.0)
        self.assertGreater(later_hours, first_hours)
        self.assertIn("rate_below_plan", plan.warnings)

    def test_a_target_that_cannot_be_met_at_the_measured_rate_is_called_unlikely(self):
        plan = make_plan(target=18.0, rate=3.0, deadline_minutes=60)
        slots = quarter_slots([0.5] * 8)
        result = step(plan, snapshot("connected"), slots, 0)
        self.assertEqual(plan.phase, PHASE_UNLIKELY)
        self.assertIn("deadline_unlikely", plan.warnings)
        # It still charges as soon as it can rather than giving up.
        self.assertEqual(result.command, "turn_on")

    def test_recent_session_rates_replace_the_configured_rate(self):
        plan = make_plan(target=18.0, rate=11.0)
        step(plan, snapshot("connected"), CHEAP_NOW, 0, rates=[7.0, 7.4, 7.2])
        self.assertAlmostEqual(plan.rate_kw, 7.2)

    def test_the_plan_completes_and_stops_the_charger_at_the_target(self):
        plan = make_plan(target=7.2)
        step(plan, snapshot("charging", power=7.2, energy=0.0), CHEAP_NOW, 0)
        result = step(plan, snapshot("charging", power=7.2, energy=7.3, minutes=60), CHEAP_NOW, 60)
        self.assertEqual(plan.phase, PHASE_COMPLETE)
        self.assertEqual(result.command, "turn_off")

    def test_a_plan_past_its_deadline_expires_without_touching_the_charger(self):
        plan = make_plan(deadline_minutes=60)
        result = step(plan, snapshot("charging", power=7.2, minutes=80), CHEAP_NOW, 80)
        self.assertEqual(plan.phase, PHASE_EXPIRED)
        self.assertIsNone(result.command)


class CommandBackoffTests(unittest.TestCase):
    def test_an_unobeyed_command_is_not_repeated_at_once_and_is_reported_unconfirmed(self):
        plan = make_plan()
        self.assertEqual(step(plan, snapshot("connected"), CHEAP_NOW, 0).command, "turn_on")
        self.assertIsNone(step(plan, snapshot("connected", minutes=1), CHEAP_NOW, 1).command)
        retry = step(plan, snapshot("connected", minutes=3), CHEAP_NOW, 3)
        self.assertEqual(retry.command, "turn_on")
        self.assertIn("command_unconfirmed", plan.warnings)
        self.assertEqual(plan.last_command["attempts"], 2)
        # The wait doubles.
        self.assertIsNone(step(plan, snapshot("connected", minutes=5), CHEAP_NOW, 5).command)

    def test_commands_are_capped_per_hour(self):
        plan = make_plan()
        sent = 0
        for minute in range(0, 120, 3):
            if step(plan, snapshot("connected", minutes=minute), CHEAP_NOW, minute).command:
                sent += 1
        self.assertLessEqual(sent, engine.MAX_COMMANDS_PER_HOUR * 2)


class CarLimitTests(unittest.TestCase):
    def test_the_car_reaching_its_own_limit_ends_the_plan(self):
        plan = make_plan(target=30.0)
        plan.last_command = {"kind": "turn_on", "at": at(-60).isoformat(), "attempts": 1, "confirmed_at": at(-59).isoformat()}
        step(plan, snapshot("finished", power=0, energy=10.0), CHEAP_NOW, 0)
        self.assertEqual(plan.phase, PHASE_COMPLETE)
        self.assertIn("car_limit_reached", plan.warnings)

    def test_finished_after_this_plan_stopped_the_charger_is_not_read_as_the_car_being_full(self):
        plan = make_plan(target=30.0)
        plan.last_command = {"kind": "turn_off", "at": at(-1).isoformat(), "attempts": 1, "confirmed_at": None}
        step(plan, snapshot("finished", power=0, energy=10.0), CHEAP_LATER, 0)
        self.assertNotEqual(plan.phase, PHASE_COMPLETE)


class ReachPercentTests(unittest.TestCase):
    def test_the_battery_sensor_sets_what_remains_and_a_silent_sensor_is_carried_forward(self):
        plan = make_plan(target=80.0, kind=TARGET_REACH_PERCENT, capacity=75.0)
        fresh = engine.BatteryReading(percent=62.0, timestamp=at(-5))
        step(plan, snapshot("charging", power=7.2, energy=0.0), CHEAP_NOW, 0, battery=fresh)
        self.assertAlmostEqual(plan.remaining_kwh, 18 / 100 * 75 * 1.1, places=6)

        stale = engine.BatteryReading(percent=62.0, timestamp=at(-300))
        step(plan, snapshot("charging", power=7.2, energy=5.0, minutes=40), CHEAP_NOW, 40, battery=stale)
        self.assertAlmostEqual(plan.remaining_kwh, 18 / 100 * 75 * 1.1 - 5.0, places=6)
        self.assertIn("battery_sensor_stale", plan.warnings)


class NoPricesTests(unittest.TestCase):
    def test_without_prices_the_plan_charges_now_so_the_deadline_is_still_met(self):
        plan = make_plan()
        result = step(plan, snapshot("connected"), [], 0)
        self.assertEqual(result.command, "turn_on")
        self.assertIn("prices_missing", plan.warnings)


if __name__ == "__main__":
    unittest.main()
