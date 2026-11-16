import unittest
from datetime import timedelta

from tests.helpers import T0, at

from custom_components.hisingen_home_charging import sessions


def run_session(recorder, minutes=60, step=1.0, kwh_per_min=0.12, start=0.0, base=0.0):
    energy = base
    recorder.observe(at(start), "connected", energy)
    finished = None
    for i in range(1, int(minutes / step) + 1):
        energy = base + kwh_per_min * step * i
        finished = recorder.observe(at(start + i * step), "charging", energy, 7.2) or finished
    return finished


class SessionRecorderTests(unittest.TestCase):
    def finished_session(self):
        recorder = sessions.SessionRecorder("NX1")
        run_session(recorder)
        recorder.observe(at(61), "finished", 7.2)
        return recorder, recorder.tick(at(100), "finished")

    def test_a_session_is_recorded_with_its_energy_and_15_minute_intervals(self):
        _, record = self.finished_session()
        self.assertIsNotNone(record)
        self.assertAlmostEqual(record["energy_kwh"], 7.2, places=3)
        self.assertEqual(record["started_at"], at(0).isoformat())
        self.assertEqual(record["ended_at"], at(60).isoformat())
        self.assertAlmostEqual(sum(i["kwh"] for i in record["intervals"]), 7.2, places=3)
        self.assertTrue(all(sessions._parse(i["end"]) - sessions._parse(i["start"]) == timedelta(minutes=15)
                            for i in record["intervals"]))
        self.assertFalse(record["coarse"])

    def test_the_id_is_stable_and_depends_on_the_start(self):
        _, record = self.finished_session()
        self.assertEqual(record["id"], sessions.session_id("NX1", at(0)))
        self.assertNotEqual(record["id"], sessions.session_id("NX1", at(10)))
        self.assertNotEqual(record["id"], sessions.session_id("NX2", at(0)))

    def test_the_same_reading_delivered_twice_is_not_counted_twice(self):
        recorder = sessions.SessionRecorder("NX1")
        recorder.observe(at(0), "connected", 0.0)
        recorder.observe(at(1), "charging", 0.12)
        recorder.observe(at(1), "charging", 0.12)
        recorder.observe(at(0.5), "charging", 0.12)   # an older stamp changes nothing
        recorder.observe(at(2), "charging", 0.24)
        recorder.observe(at(2), "charging", 0.24)
        recorder.observe(at(3), "finished", 0.24)
        record = recorder.tick(at(100), "finished")
        self.assertAlmostEqual(record["energy_kwh"], 0.24, places=6)
        self.assertEqual(len(recorder.completed), 1)

    def test_a_restart_mid_session_loses_nothing_and_adds_nothing(self):
        straight = sessions.SessionRecorder("NX1")
        run_session(straight)
        straight.observe(at(61), "finished", 7.2)
        expected = straight.tick(at(100), "finished")

        first = sessions.SessionRecorder("NX1")
        first.observe(at(0), "connected", 0.0)
        for i in range(1, 31):
            first.observe(at(i), "charging", 0.12 * i, 7.2)
        resumed = sessions.SessionRecorder.from_dict("NX1", first.to_dict())
        for i in range(31, 61):
            resumed.observe(at(i), "charging", 0.12 * i, 7.2)
        resumed.observe(at(61), "finished", 7.2)
        record = resumed.tick(at(100), "finished")
        self.assertEqual(record["id"], expected["id"])
        self.assertAlmostEqual(record["energy_kwh"], expected["energy_kwh"], places=3)
        self.assertEqual(len(resumed.completed), 1)

    def test_a_counter_reset_closes_the_session_and_starts_the_next(self):
        recorder = sessions.SessionRecorder("NX1")
        run_session(recorder, minutes=30)
        finished = recorder.observe(at(40), "connected", 0.0)
        self.assertIsNotNone(finished)
        self.assertAlmostEqual(finished["energy_kwh"], 3.6, places=3)
        recorder.observe(at(50), "charging", 1.2)
        self.assertIsNone(recorder.tick(at(51), "charging"))

    def test_the_cable_coming_out_closes_the_session_at_once(self):
        recorder = sessions.SessionRecorder("NX1")
        run_session(recorder, minutes=30)
        finished = recorder.observe(at(31), "idle", 3.6)
        self.assertIsNotNone(finished)
        self.assertEqual(finished["ended_at"], at(30).isoformat())

    def test_a_session_still_charging_is_not_finished_by_the_clock(self):
        recorder = sessions.SessionRecorder("NX1")
        run_session(recorder, minutes=30)
        self.assertIsNone(recorder.tick(at(200), "charging"))
        self.assertIsNone(recorder.tick(at(200), "lb_waiting"))
        self.assertIsNotNone(recorder.tick(at(200), "connected"))

    def test_a_rise_across_a_long_gap_is_marked_coarse_and_carries_no_intervals(self):
        recorder = sessions.SessionRecorder("NX1")
        recorder.observe(at(0), "connected", 0.0)
        recorder.observe(at(10), "charging", 1.0)
        recorder.observe(at(60), "charging", 6.0)    # Home Assistant was down for 50 minutes
        recorder.observe(at(61), "finished", 6.0)
        record = recorder.tick(at(100), "finished")
        self.assertTrue(record["coarse"])
        self.assertEqual(record["intervals"], [])
        self.assertAlmostEqual(record["energy_kwh"], 6.0, places=3)

    def test_noise_is_not_a_session(self):
        recorder = sessions.SessionRecorder("NX1")
        recorder.observe(at(0), "connected", 0.0)
        recorder.observe(at(1), "charging", 0.05)
        self.assertIsNone(recorder.tick(at(100), "connected"))
        self.assertEqual(recorder.completed, [])

    def test_vehicle_percent_is_kept_from_a_sensor_when_one_is_configured(self):
        recorder = sessions.SessionRecorder("NX1")
        recorder.observe(at(0), "connected", 0.0, soc_percent=41.0)
        for i in range(1, 61):
            recorder.observe(at(i), "charging", 0.12 * i, 7.2, soc_percent=41.0 + i * 0.5)
        recorder.observe(at(61), "finished", 7.2, soc_percent=71.0)
        record = recorder.tick(at(100), "finished")
        self.assertEqual(record["vehicle_start_percent"], 41.0)
        self.assertEqual(record["vehicle_end_percent"], 71.0)

    def test_sessions_since_filters_by_end_time(self):
        recorder, _ = self.finished_session()
        self.assertEqual(len(recorder.sessions_since(at(30))), 1)
        self.assertEqual(len(recorder.sessions_since(at(90))), 0)
        self.assertEqual(len(recorder.sessions_since(None)), 1)

    def test_average_power_is_taken_over_the_time_it_was_charging(self):
        _, record = self.finished_session()
        self.assertAlmostEqual(sessions.session_average_power_kw(record), 7.2, delta=0.2)
        self.assertIsNone(sessions.session_average_power_kw({"intervals": []}))


if __name__ == "__main__":
    unittest.main()
