"""Timed evaluation run: watch the simulator until N laps, a crash, a stall or a timeout.

The controller container drives as usual; this process only reads simulator telemetry
(and requests one reset at the start), then prints and saves a summary.
"""

import argparse
import json
import math
import os
import signal
import time

PREFIX = "/autodrive/roboracer_1"
RESULTS_DIR = "/workshop/results"
STOPPED_SPEED = 0.05      # m/s: below this the car counts as stationary
TELEPORT_DISTANCE = 1.0   # m between odometry samples: a reset, not driving
LAP_TIME_WAIT = 1.0       # s to wait for the simulator's lap time after the final lap


class RunTracker:
    """Pure bookkeeping for one evaluation run; times are monotonic seconds."""

    def __init__(self, laps=3, timeout=300.0, stall_seconds=15.0):
        self.target_laps, self.timeout, self.stall_seconds = laps, timeout, stall_seconds
        self.started = None

    def start(self, now, lap_count, collisions):
        self.started = self.lap_started = self.last_moving = now
        self.lap_count, self.collisions = lap_count, collisions
        self.start_collisions = collisions
        self.laps = []            # one dict per completed lap
        self.pending_lap = None   # lap waiting for the simulator's own lap time
        self.position = None
        self.distance = self.top_speed = 0.0
        self.speed = 0.0
        self.finished_at = None

    def update_odom(self, now, x, y, speed):
        if self.position is not None:
            step = math.hypot(x - self.position[0], y - self.position[1])
            if step < TELEPORT_DISTANCE:
                self.distance += step
        self.position = (x, y)
        self.speed = abs(speed)
        self.top_speed = max(self.top_speed, self.speed)
        if self.speed >= STOPPED_SPEED:
            self.last_moving = now

    def update_laps(self, now, lap_count):
        if lap_count > self.lap_count and self.finished_at is None:
            for _ in range(lap_count - self.lap_count):
                self.laps.append({"lap": len(self.laps) + 1,
                                  "time_s": round(now - self.lap_started, 3),
                                  "source": "measured"})
            self.lap_started = now
            self.pending_lap = self.laps[-1]
        self.lap_count = lap_count

    def update_last_lap_time(self, value):
        # The simulator times laps itself; prefer its value once it reports one.
        if self.pending_lap is not None and math.isfinite(value) and value > 0:
            self.pending_lap.update(time_s=round(value, 3), source="simulator")
            self.pending_lap = None

    def update_collisions(self, collisions):
        self.collisions = collisions

    def outcome(self, now):
        """Return why the run is over, or None while it continues."""
        if self.collisions > self.start_collisions:
            return "crashed"
        if len(self.laps) >= self.target_laps:
            if self.pending_lap is None or now - self.lap_started >= LAP_TIME_WAIT:
                return "completed"
            return None
        if now - self.last_moving >= self.stall_seconds:
            return "stalled"
        if now - self.started >= self.timeout:
            return "timeout"
        return None

    def current_lap_time(self, now):
        return now - self.lap_started

    def summary(self, now, result, controller=""):
        laps = self.laps[:self.target_laps]
        times = [lap["time_s"] for lap in laps]
        if result == "completed" and laps:
            # The run ends at the line, not after the lap-time wait.
            now = min(now, self.lap_started)
        elapsed = now - self.started
        return {
            "controller": controller,
            "result": result,
            "laps_completed": len(laps),
            "laps_target": self.target_laps,
            "lap_times_s": times,
            "best_lap_s": min(times) if times else None,
            "average_lap_s": round(sum(times) / len(times), 3) if times else None,
            "total_time_s": round(elapsed, 3),
            "top_speed_mps": round(self.top_speed, 3),
            "average_speed_mps": round(self.distance / elapsed, 3) if elapsed > 0 else 0.0,
            "distance_m": round(self.distance, 2),
            "collisions": self.collisions - self.start_collisions,
            "laps": laps,
        }


def format_summary(summary):
    def seconds(value):
        return "-" if value is None else f"{value:.2f} s"

    lines = [
        "",
        "=" * 44,
        f" Evaluation result: {summary['result'].upper()}",
        "=" * 44,
        f" Controller        {summary['controller']}",
        f" Laps completed    {summary['laps_completed']} / {summary['laps_target']}",
    ]
    lines += [f"   Lap {lap['lap']}           {seconds(lap['time_s'])}"
              + (" (measured)" if lap["source"] == "measured" else "")
              for lap in summary["laps"]]
    lines += [
        f" Best lap          {seconds(summary['best_lap_s'])}",
        f" Average lap       {seconds(summary['average_lap_s'])}",
        f" Total time        {seconds(summary['total_time_s'])}",
        f" Top speed         {summary['top_speed_mps']:.2f} m/s",
        f" Average speed     {summary['average_speed_mps']:.2f} m/s",
        f" Distance          {summary['distance_m']:.1f} m",
        f" Collisions        {summary['collisions']}",
        "=" * 44,
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller", default="controller")
    parser.add_argument("--laps", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--stall", type=float, default=15.0)
    parser.add_argument("--wait", type=float, default=60.0,
                        help="seconds to wait for simulator telemetry")
    parser.add_argument("--no-reset", action="store_true")
    options = parser.parse_args()

    import rclpy
    from rclpy.node import Node
    from rclpy.qos import qos_profile_sensor_data
    from rclpy.signals import SignalHandlerOptions
    from nav_msgs.msg import Odometry
    from std_msgs.msg import Bool, Float32, Int32

    from runtime.core import read_odometry

    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    node = Node("workshop_evaluator")
    latest = {}
    tracker = RunTracker(options.laps, options.timeout, options.stall)

    def on_laps(msg):
        latest["laps"] = msg.data
        if tracker.started is not None:
            tracker.update_laps(time.monotonic(), msg.data)

    def on_last_lap_time(msg):
        if tracker.started is not None:
            tracker.update_last_lap_time(float(msg.data))

    def on_collisions(msg):
        latest["collisions"] = msg.data
        if tracker.started is not None:
            tracker.update_collisions(msg.data)

    def on_odom(msg):
        try:
            x, y, _, speed = read_odometry(msg)
        except ValueError:
            return
        latest["odom"] = True
        if tracker.started is not None:
            tracker.update_odom(time.monotonic(), x, y, speed)

    node.create_subscription(Int32, PREFIX + "/lap_count", on_laps, 10)
    node.create_subscription(Float32, PREFIX + "/last_lap_time", on_last_lap_time, 10)
    node.create_subscription(Int32, PREFIX + "/collision_count", on_collisions, 10)
    node.create_subscription(Odometry, PREFIX + "/odom", on_odom, qos_profile_sensor_data)
    reset = node.create_publisher(Bool, "/autodrive/reset_command", 1)

    interrupted = False

    def stop(*_):
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    def spin(seconds):
        deadline = time.monotonic() + seconds
        while not interrupted and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.05)

    try:
        print("Waiting for simulator telemetry. In Unity select Connection and Autonomous.")
        deadline = time.monotonic() + options.wait
        while not interrupted and not {"laps", "collisions", "odom"} <= latest.keys():
            if time.monotonic() > deadline:
                print("No simulator telemetry received; is the simulator connected?")
                return 2
            spin(0.1)
        if interrupted:
            return 2
        if not options.no_reset:
            print("Resetting the car to the start.")
            reset.publish(Bool(data=True))
            spin(0.5)
            reset.publish(Bool(data=False))
            spin(2.0)  # let lap/collision counters and odometry settle

        tracker.start(time.monotonic(), latest["laps"], latest["collisions"])
        print(f"Evaluating {options.controller}: {options.laps} laps, "
              f"stop on crash, {options.stall:.0f} s stall or {options.timeout:.0f} s timeout.")
        result, next_report = None, 0.0
        while result is None:
            spin(0.05)
            now = time.monotonic()
            result = "interrupted" if interrupted else tracker.outcome(now)
            if now >= next_report:
                next_report = now + 1.0
                lap = min(len(tracker.laps) + 1, options.laps)
                print(f"  Lap {lap}/{options.laps} | lap time {tracker.current_lap_time(now):6.1f} s"
                      f" | speed {tracker.speed:4.2f} m/s | top {tracker.top_speed:4.2f} m/s"
                      f" | collisions {tracker.collisions - tracker.start_collisions}")

        summary = tracker.summary(time.monotonic(), result, options.controller)
        print(format_summary(summary))
        if os.path.isdir(RESULTS_DIR):
            name = time.strftime("%Y%m%d-%H%M%S") + "-" + options.controller + ".json"
            with open(os.path.join(RESULTS_DIR, name), "w", encoding="utf-8") as out:
                json.dump(summary, out, indent=2)
            print(f" Saved .runtime/results/{name}")
        return 0 if result == "completed" else 3
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
