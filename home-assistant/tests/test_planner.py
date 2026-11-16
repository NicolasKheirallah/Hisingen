import unittest

from tests.helpers import at, quarter_slots

from custom_components.hisingen_home_charging import planner


class PlannerTests(unittest.TestCase):
    def test_prefers_one_contiguous_block_when_it_costs_little_extra(self):
        # 1 h needed at 7.2 kW. The cheapest four slots are scattered at 0.40 and 0.41; the best contiguous
        # hour starts at 00:45 and averages 0.4075, within the tolerance, so it is chosen as one block.
        prices = [0.60, 0.40, 0.60, 0.40, 0.41, 0.41, 0.41, 0.41]
        plan = planner.plan_windows(quarter_slots(prices), at(0), at(120), needed_kwh=7.2, rate_kw=7.2)
        self.assertTrue(plan.feasible)
        self.assertEqual(len(plan.windows), 1)
        self.assertEqual(plan.windows[0].start, at(45))
        self.assertAlmostEqual(plan.windows[0].seconds, 3600)
        self.assertTrue(plan.contiguous)

    def test_splits_when_scattered_slots_are_much_cheaper(self):
        # 30 minutes needed. Three cheap slots are far apart; any contiguous half hour includes an expensive one.
        prices = [0.10, 3.00, 3.00, 0.10, 3.00, 3.00, 0.10, 3.00, 3.00, 3.00, 3.00, 3.00]
        plan = planner.plan_windows(quarter_slots(prices), at(0), at(180), needed_kwh=3.6, rate_kw=7.2)
        self.assertTrue(plan.feasible)
        self.assertAlmostEqual(sum(w.seconds for w in plan.windows), 1800)
        self.assertEqual(len(plan.windows), 2)
        self.assertFalse(plan.contiguous)
        self.assertAlmostEqual(plan.cost, 7.2 * 0.5 * 0.10, places=6)

    def test_best_contiguous_block_can_start_off_a_slot_boundary(self):
        # 20 minutes needed; the cheap run is two slots, so the block must end on the slot end.
        prices = [2.0, 0.1, 0.1, 2.0]
        plan = planner.plan_windows(quarter_slots(prices), at(0), at(60), needed_kwh=2.4, rate_kw=7.2)  # 20 min
        self.assertEqual(plan.windows[0].start, at(15))
        self.assertAlmostEqual(plan.windows[0].seconds, 1200)

    def test_infeasible_uses_every_slot_and_reports_the_shortfall(self):
        plan = planner.plan_windows(quarter_slots([0.5] * 4), at(0), at(60), needed_kwh=14.4, rate_kw=7.2)  # 2 h needed
        self.assertFalse(plan.feasible)
        self.assertAlmostEqual(plan.shortfall_kwh, 7.2, places=6)
        self.assertEqual(plan.windows[0].start, at(0))
        self.assertEqual(plan.windows[-1].end, at(60))

    def test_only_the_time_left_before_the_deadline_is_used(self):
        plan = planner.plan_windows(quarter_slots([0.5] * 8), at(30), at(90), needed_kwh=3.6, rate_kw=7.2)
        for window in plan.windows:
            self.assertGreaterEqual(window.start, at(30))
            self.assertLessEqual(window.end, at(90))

    def test_the_current_partial_slot_counts_for_what_is_left_of_it(self):
        slots = quarter_slots([0.1, 5.0, 5.0, 5.0])
        plan = planner.plan_windows(slots, at(10), at(60), needed_kwh=0.6, rate_kw=7.2)  # 5 min, inside the cheap slot
        self.assertEqual(plan.windows[0].start, at(10))
        self.assertAlmostEqual(plan.windows[0].avg_price, 0.1)

    def test_nothing_needed_means_no_windows(self):
        plan = planner.plan_windows(quarter_slots([0.5] * 4), at(0), at(60), needed_kwh=0, rate_kw=7.2)
        self.assertEqual(plan.windows, ())
        self.assertTrue(plan.feasible)

    def test_slots_from_points_end_where_the_next_begins(self):
        slots = planner.slots_from_points([(at(0), 1.0), (at(15), 2.0), (at(30), 3.0)])
        self.assertEqual([s.end for s in slots], [at(15), at(30), at(45)])

    def test_missing_prices_are_filled_at_the_average_and_marked_as_estimates(self):
        slots = quarter_slots([1.0, 3.0])
        filled = planner.fill_missing(slots, at(90))
        self.assertEqual(filled[-1].end, at(90))
        self.assertTrue(all(s.estimated and abs(s.price - 2.0) < 1e-9 for s in filled[2:]))
        self.assertEqual(planner.fill_missing([], at(90)), [])


if __name__ == "__main__":
    unittest.main()
