import math
from types import SimpleNamespace as NS
import unittest

import controller
from examples.follow_the_gap import drive as example
from runtime.bridge import CommandExpiry, REQUIRED_FIELDS, install_startup_guard
from runtime.evaluate import RunTracker, format_summary
from runtime.core import MAX_THROTTLE, clean_scan, fresh_stamp, read_odometry, simulator_command
from workshop_api import DriveCommand, Observation


def observation(ranges=None, speed=0.0):
    return Observation(tuple(ranges or [4.0] * 181), -math.pi / 2, math.pi / 180,
                       10.0, speed, 0.0, 0.0, 0.0, 0.05)


class ParticipantTests(unittest.TestCase):
    def test_participant_controller_returns_a_valid_command(self):
        # Keep this useful after participants replace the stopped starter.
        result = controller.drive(observation())
        self.assertIsInstance(result, DriveCommand)
        self.assertTrue(math.isfinite(result.speed_mps))
        self.assertTrue(math.isfinite(result.steering_rad))

    def test_example_drives_straight_in_symmetric_free_space(self):
        result = example(observation())
        self.assertGreater(result.speed_mps, 0)
        self.assertLessEqual(result.speed_mps, 1)
        self.assertAlmostEqual(result.steering_rad, 0, places=7)

    def test_example_turns_away_from_blocked_right_side(self):
        result = example(observation([0.3] * 60 + [4.0] * 121))
        self.assertGreater(result.steering_rad, 0)

    def test_example_stops_without_a_gap(self):
        self.assertEqual(example(observation([0.2] * 181)), DriveCommand())

    def test_sectors_handle_zero_to_two_pi_scans(self):
        obs = Observation(tuple(range(360)), 0, math.pi / 180, 400, 0, 0, 0, 0, 0.05)
        sector = obs.sector(-0.03, 0.03)
        self.assertEqual(set(sector), {0, 1, 359})

    def test_no_ray_in_forward_sector_is_not_clear_space(self):
        obs = Observation((4.0,) * 32, 1.0, 0.01, 10, 0, 0, 0, 0, 0.05)
        self.assertEqual(simulator_command(DriveCommand(1, 0), obs), (0, 0))


class InputTests(unittest.TestCase):
    def scan(self, ranges):
        return NS(ranges=ranges, angle_min=-math.pi, angle_increment=0.01,
                  range_min=0.05, range_max=10.0)

    def test_clear_no_return_is_valid_but_corrupt_is_unknown(self):
        result = clean_scan(self.scan([math.inf] * 30 + [math.nan, -math.inf]))
        self.assertEqual(result, (10.0,) * 30 + (0.0, 0.0))

    def test_mostly_invalid_scan_is_rejected(self):
        with self.assertRaises(ValueError):
            clean_scan(self.scan([math.nan] * 32))

    def test_invalid_angle_and_range_metadata_rejected(self):
        for key, value in [('angle_min', math.nan), ('angle_increment', 0), ('range_max', 0)]:
            msg = self.scan([1.0] * 32)
            setattr(msg, key, value)
            with self.assertRaises(ValueError):
                clean_scan(msg)

    def test_source_timestamp_freshness(self):
        self.assertTrue(fresh_stamp(99.9, 100))
        for stamp in (0, 1, 101, math.nan):
            self.assertFalse(fresh_stamp(stamp, 100))

    def test_body_speed_is_not_rotated_by_world_heading(self):
        q = NS(x=0, y=0, z=math.sin(math.pi / 4), w=math.cos(math.pi / 4))
        msg = NS(pose=NS(pose=NS(position=NS(x=1, y=2), orientation=q)),
                 twist=NS(twist=NS(linear=NS(x=0.7))))
        self.assertAlmostEqual(read_odometry(msg)[3], 0.7)
        self.assertAlmostEqual(read_odometry(msg)[2], math.pi / 2)
        q.w = 0
        with self.assertRaises(ValueError):
            read_odometry(msg)


class OutputTests(unittest.TestCase):
    def test_speed_steering_and_throttle_are_bounded(self):
        throttle, steering = simulator_command(DriveCommand(100, 10), observation())
        self.assertLessEqual(throttle, MAX_THROTTLE)
        self.assertEqual(steering, 1)
        self.assertEqual(throttle, simulator_command(DriveCommand(1, 10), observation())[0])

    def test_stop_reverse_and_overspeed_remove_throttle(self):
        for command, speed in ((DriveCommand(), 0), (DriveCommand(-1), 0), (DriveCommand(1), 2)):
            self.assertEqual(simulator_command(command, observation(speed=speed))[0], 0)

    def test_front_unknown_or_obstacle_removes_throttle(self):
        for distance in (0, 0.2):
            scan = [4.0] * 181
            scan[90] = distance
            self.assertEqual(simulator_command(DriveCommand(1), observation(scan)), (0, 0))

    def test_invalid_controller_result_is_rejected(self):
        for command in (None, (1, 0), DriveCommand(math.nan), DriveCommand(1, math.inf)):
            with self.assertRaises(ValueError):
                simulator_command(command, observation())


class BridgeTests(unittest.TestCase):
    def test_expiry_is_independent_of_controller_callbacks(self):
        now = [10.0]
        guard = CommandExpiry(clock=lambda: now[0])
        guard.receive('throttle', 0.1)
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')
        guard.receive('steering', 0.2)
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.1')
        now[0] += 0.501
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')
        guard.receive('throttle', 0.1)
        self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')

    def test_invalid_command_and_reset_clear_both_axes(self):
        guard = CommandExpiry()
        for invalidate in (lambda: guard.receive('throttle', math.nan), guard.invalidate):
            guard.receive('throttle', 0.1)
            guard.receive('steering', 0.2)
            invalidate()
            self.assertEqual(guard.gate({})['V1 Throttle'], '0.0')
            self.assertEqual(guard.gate({})['V1 Steering'], '0.0')

    def test_incomplete_startup_packet_still_gets_stopped_reply(self):
        emitted, forwarded = [], []
        stock = NS(sio=NS(on=lambda event: lambda fn: fn,
                          emit=lambda *a, **kw: emitted.append(kw)),
                   bridge=lambda *args: forwarded.append(args))
        handler = install_startup_guard(stock)
        handler('client', {'V1 Throttle': '1'})
        self.assertEqual(emitted[0]['data']['V1 Throttle'], '0')
        self.assertEqual(forwarded, [])
        frame = dict.fromkeys(REQUIRED_FIELDS, 'value')
        handler('client', frame)
        self.assertEqual(forwarded, [('client', frame)])


class EvaluationTests(unittest.TestCase):
    def tracker(self):
        tracker = RunTracker(laps=3, timeout=300, stall_seconds=15)
        tracker.start(100.0, lap_count=2, collisions=1)  # counters need not start at zero
        return tracker

    def test_three_laps_complete_with_simulator_lap_times(self):
        tracker = self.tracker()
        for lap, now in enumerate((120.0, 141.0, 160.5), start=3):
            tracker.update_odom(now - 1, 1.0, 0.0, 0.9)
            tracker.update_laps(now, lap)
            tracker.update_last_lap_time(now - 100 - 0.5 * (lap - 2))
        self.assertEqual(tracker.outcome(160.5), "completed")
        summary = tracker.summary(170.0, "completed", "examples.follow_the_gap")
        self.assertEqual(summary["laps_completed"], 3)
        self.assertEqual([lap["source"] for lap in summary["laps"]], ["simulator"] * 3)
        self.assertEqual(summary["total_time_s"], 60.5)  # ends at the line
        self.assertEqual(summary["top_speed_mps"], 0.9)
        self.assertEqual(summary["collisions"], 0)
        self.assertIn("COMPLETED", format_summary(summary))

    def test_measured_lap_time_is_kept_until_simulator_reports(self):
        tracker = self.tracker()
        tracker.update_laps(125.0, 3)
        tracker.update_last_lap_time(0.0)  # not a lap time yet
        self.assertEqual(tracker.laps[0], {"lap": 1, "time_s": 25.0, "source": "measured"})

    def test_final_lap_waits_briefly_for_simulator_time(self):
        tracker = self.tracker()
        tracker.update_laps(110.0, 5)
        self.assertEqual(len(tracker.laps), 3)
        self.assertIsNone(tracker.outcome(110.2))
        self.assertEqual(tracker.outcome(111.0), "completed")

    def test_new_collision_ends_run_as_crash(self):
        tracker = self.tracker()
        tracker.update_odom(101.0, 0.5, 0.0, 0.5)
        tracker.update_collisions(2)
        self.assertEqual(tracker.outcome(102.0), "crashed")
        self.assertEqual(tracker.summary(102.0, "crashed")["collisions"], 1)

    def test_stall_and_timeout(self):
        tracker = self.tracker()
        self.assertEqual(tracker.outcome(115.0), "stalled")
        tracker = RunTracker(laps=3, timeout=30, stall_seconds=15)
        tracker.start(0.0, 0, 0)
        for now in range(31):
            tracker.update_odom(float(now), now * 0.5, 0.0, 0.5)
        self.assertEqual(tracker.outcome(30.0), "timeout")

    def test_distance_ignores_reset_teleport(self):
        tracker = self.tracker()
        for now, x in ((101, 0.0), (102, 0.5), (103, 10.0), (104, 10.5)):
            tracker.update_odom(now, x, 0.0, 0.5)
        self.assertAlmostEqual(tracker.distance, 1.0)


if __name__ == '__main__':
    unittest.main()
