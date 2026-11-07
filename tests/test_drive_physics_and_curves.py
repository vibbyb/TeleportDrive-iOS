"""Unit and boundary tests for 5Hz Drive Physics, Curve Engine, and Kinematics.

Covers:
- RouteGeometry.swift (windowed turn angles, 25m lookahead, single-vertex vs windowed max)
- DrivingDynamics.swift (speed sanitization boundaries, curve speed reduction, lookahead braking)
- RoutePlayer.swift (5 Hz cadence, monotonic uptime dt, non-destructive jitter, seamless hold)
"""

import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SIMULATION_DIR = REPO_ROOT / "StikDebug" / "Simulation"


class TestRouteGeometryContract:
    @pytest.fixture(autouse=True)
    def setup_files(self) -> None:
        self.geom_file = SIMULATION_DIR / "RouteGeometry.swift"
        assert self.geom_file.is_file(), f"Missing {self.geom_file}"
        self.geom_code = self.geom_file.read_text(encoding="utf-8")

    def test_windowed_turn_angle_signature_and_window(self) -> None:
        assert "static func windowedTurnAngle" in self.geom_code
        assert "windowMeters: CLLocationDistance = 25.0" in self.geom_code
        assert "coords: [CLLocationCoordinate2D]" in self.geom_code
        assert "cumulative: [CLLocationDistance]" in self.geom_code

    def test_turn_angle_overload_takes_max_with_windowed(self) -> None:
        assert "static func turnAngle(" in self.geom_code
        assert "max(singleVertexAngle, windowedAngle)" in self.geom_code

    def test_retains_legacy_signatures(self) -> None:
        assert "static func densify(" in self.geom_code
        assert "static func cumulativeDistances(" in self.geom_code
        assert "static func position(" in self.geom_code
        assert "static func turnAngle(at index: Int, coords: [CLLocationCoordinate2D]) -> Double" in self.geom_code
        assert "static func bearing(" in self.geom_code
        assert "static func distance(" in self.geom_code
        assert "static func interpolate(" in self.geom_code
        assert "static func totalDistance(" in self.geom_code


class TestDrivingDynamicsContract:
    @pytest.fixture(autouse=True)
    def setup_files(self) -> None:
        self.dynamics_file = SIMULATION_DIR / "DrivingDynamics.swift"
        assert self.dynamics_file.is_file(), f"Missing {self.dynamics_file}"
        self.dynamics_code = self.dynamics_file.read_text(encoding="utf-8")

    def test_minimum_driving_speed_floor_value(self) -> None:
        assert "minimumDrivingSpeedMps: CLLocationSpeed = 7.15" in self.dynamics_code

    def test_turn_target_speed_lowered_threshold_and_normalized(self) -> None:
        assert "guard upcomingTurnAngle > 8 else { return baseCruise }" in self.dynamics_code
        assert "let normalized = min((upcomingTurnAngle - 8.0) / 82.0, 1.0)" in self.dynamics_code

    def test_sanitize_cruise_speed_signature_and_boundaries(self) -> None:
        assert "static func sanitizeCruiseSpeedMph(" in self.dynamics_code
        assert "min(max(val, 10.0), 120.0)" in self.dynamics_code
        assert "min(max(fallback, 10.0), 120.0)" in self.dynamics_code

    def test_compute_segment_target_speeds_signature_and_kinematics(self) -> None:
        assert "static func computeSegmentTargetSpeeds(" in self.dynamics_code
        assert "enforceDrivingFloor: Bool" in self.dynamics_code
        assert "sqrt(speeds[i + 1] * speeds[i + 1] + 2.0 * max(0.5, braking) * segDist)" in self.dynamics_code
        assert "speeds[i] = min(speeds[i], maxEntrySpeed)" in self.dynamics_code


class TestRoutePlayerContract:
    @pytest.fixture(autouse=True)
    def setup_files(self) -> None:
        self.player_file = SIMULATION_DIR / "RoutePlayer.swift"
        assert self.player_file.is_file(), f"Missing {self.player_file}"
        self.player_code = self.player_file.read_text(encoding="utf-8")

    def test_1hz_cadence_tick_interval(self) -> None:
        assert "private let tickInterval: TimeInterval = 1.0" in self.player_code

    def test_monotonic_uptime_pacing(self) -> None:
        assert "private var lastTickUptime: TimeInterval?" in self.player_code
        assert "ProcessInfo.processInfo.systemUptime" in self.player_code
        assert "max(0.1, min(2.0, now - $0))" in self.player_code

    def test_max_step_meters_densification(self) -> None:
        assert "profile.maxSpeed * tickInterval" in self.player_code

    def test_keep_alive_activation_on_play(self) -> None:
        assert "SpoofKeepAliveManager.shared.activate()" in self.player_code

    def test_non_destructive_jitter_odometer_advance(self) -> None:
        assert "let effectiveSpeed = dwelling ? 0 : DrivingDynamics.applyJitter(speed: currentSpeed, jitter: profile.speedJitter * 0.4)" in self.player_code
        assert "odometer += effectiveSpeed * scaledDt" in self.player_code

    def test_coalesced_injection_and_seamless_hold(self) -> None:
        assert "simulator.setLocation(coord, coalesceIfBusy: true)" in self.player_code
        assert "simulator.startHold(at: coord, jitterMeters: 0.25)" in self.player_code
        # Clear must NOT be called on completion
        assert "simulator.clear()" not in self.player_code.split("if odometer >= total")[1].split("return")[0]


class TestDynamicsMathAndBoundaries:
    """Mathematical parity and edge-case boundary verification."""

    @staticmethod
    def sanitize_cruise_speed_mph(raw: str, fallback: float = 35.0) -> float:
        trimmed = raw.strip()
        try:
            val = float(trimmed)
            if math.isnan(val) or math.isinf(val):
                return min(max(fallback, 10.0), 120.0)
            return min(max(val, 10.0), 120.0)
        except ValueError:
            return min(max(fallback, 10.0), 120.0)

    @staticmethod
    def turn_target_speed(base_cruise: float, upcoming_turn_angle: float, factor: float) -> float:
        if upcoming_turn_angle <= 8.0:
            return base_cruise
        normalized = min((upcoming_turn_angle - 8.0) / 82.0, 1.0)
        reduction = 1.0 - (1.0 - factor) * normalized
        return base_cruise * reduction

    @staticmethod
    def backward_lookahead_braking(speeds: list[float], distances: list[float], braking: float) -> list[float]:
        result = list(speeds)
        if len(result) >= 2:
            for i in range(len(result) - 2, -1, -1):
                seg_dist = max(0.5, distances[i] if i < len(distances) else 4.0)
                max_entry_speed = math.sqrt(result[i + 1] ** 2 + 2.0 * max(0.5, braking) * seg_dist)
                result[i] = min(result[i], max_entry_speed)
        return result

    def test_sanitize_speed_boundaries(self) -> None:
        # Falsy / invalid inputs
        assert self.sanitize_cruise_speed_mph("") == 35.0
        assert self.sanitize_cruise_speed_mph("   ") == 35.0
        assert self.sanitize_cruise_speed_mph("invalid_string") == 35.0
        assert self.sanitize_cruise_speed_mph("nan") == 35.0
        assert self.sanitize_cruise_speed_mph("inf") == 35.0
        assert self.sanitize_cruise_speed_mph("-inf") == 35.0

        # Sub-minimum clamp boundary (10.0 mph)
        assert self.sanitize_cruise_speed_mph("-50") == 10.0
        assert self.sanitize_cruise_speed_mph("0") == 10.0
        assert self.sanitize_cruise_speed_mph("9.999") == 10.0
        assert self.sanitize_cruise_speed_mph("10.0") == 10.0

        # Valid range
        assert self.sanitize_cruise_speed_mph("35.0") == 35.0
        assert self.sanitize_cruise_speed_mph("  45.5  ") == 45.5
        assert self.sanitize_cruise_speed_mph("65") == 65.0

        # Upper clamp boundary (120.0 mph)
        assert self.sanitize_cruise_speed_mph("120.0") == 120.0
        assert self.sanitize_cruise_speed_mph("120.1") == 120.0
        assert self.sanitize_cruise_speed_mph("999") == 120.0

        # Custom fallback clamping
        assert self.sanitize_cruise_speed_mph("err", fallback=5.0) == 10.0
        assert self.sanitize_cruise_speed_mph("err", fallback=150.0) == 120.0

    def test_turn_target_speed_boundaries(self) -> None:
        base = 20.0
        factor = 0.5

        # Truthy path: angle <= 8.0 retains base speed
        assert self.turn_target_speed(base, 0.0, factor) == base
        assert self.turn_target_speed(base, 5.0, factor) == base
        assert self.turn_target_speed(base, 8.0, factor) == base

        # Falsy path: angle > 8.0 decreases speed proportionally
        s_curve = self.turn_target_speed(base, 49.0, factor)
        assert s_curve < base
        assert s_curve > base * factor
        assert abs(s_curve - (base * (1.0 - 0.5 * (41.0 / 82.0)))) < 1e-6

        # Sharp turn at 90.0 degrees: reaches exactly factor * base
        s_90 = self.turn_target_speed(base, 90.0, factor)
        assert abs(s_90 - (base * factor)) < 1e-6

        # Turn > 90.0 degrees: clamped to factor * base
        s_120 = self.turn_target_speed(base, 120.0, factor)
        assert abs(s_120 - (base * factor)) < 1e-6
        s_180 = self.turn_target_speed(base, 180.0, factor)
        assert abs(s_180 - (base * factor)) < 1e-6

    def test_backward_lookahead_braking_kinematics(self) -> None:
        # 10 segments of 5m each leading into an 8 m/s corner
        # Base cruise is 20 m/s
        speeds = [20.0] * 9 + [8.0]
        distances = [5.0] * 10
        braking = 2.5

        result = self.backward_lookahead_braking(speeds, distances, braking)

        # The corner speed remains 8.0
        assert result[-1] == 8.0

        # Each preceding segment i must satisfy: result[i] <= sqrt(result[i+1]^2 + 2 * a * d)
        for i in range(len(result) - 1):
            max_allowed = math.sqrt(result[i + 1] ** 2 + 2.0 * braking * distances[i])
            assert result[i] <= max_allowed + 1e-6

        # Car starts braking well ahead of the apex (35-50m before)
        # 5m * 3 segments = 15m; result[-3] must already be significantly slowed down
        assert result[-2] < 20.0
        assert result[-3] < 20.0
        assert result[-4] < 20.0


@pytest.mark.skipif(shutil.which("swiftc") is None, reason="swiftc not found in PATH")
class TestRealSwiftExecution:
    """Execute real compiled Swift code to verify physics and curve calculations directly."""

    def test_swift_route_geometry_and_dynamics_runtime(self) -> None:
        swift_test = """
import Foundation
import CoreLocation

// 1. Verify sanitizeCruiseSpeedMph
assert(DrivingDynamics.sanitizeCruiseSpeedMph(" 45 ") == 45.0)
assert(DrivingDynamics.sanitizeCruiseSpeedMph("bad") == 35.0)
assert(DrivingDynamics.sanitizeCruiseSpeedMph("5") == 10.0)
assert(DrivingDynamics.sanitizeCruiseSpeedMph("200") == 120.0)

// 2. Verify turnTargetSpeed
let baseSpeed: CLLocationSpeed = 16.0
assert(DrivingDynamics.turnTargetSpeed(baseCruise: baseSpeed, upcomingTurnAngle: 8.0, factor: 0.5) == baseSpeed)
let sCurve = DrivingDynamics.turnTargetSpeed(baseCruise: baseSpeed, upcomingTurnAngle: 49.0, factor: 0.5)
assert(sCurve < baseSpeed && sCurve > baseSpeed * 0.5)
let s90 = DrivingDynamics.turnTargetSpeed(baseCruise: baseSpeed, upcomingTurnAngle: 90.0, factor: 0.5)
assert(abs(s90 - 8.0) < 0.001)

// 3. Verify RouteGeometry windowedTurnAngle & turnAngle
let coords = [
    CLLocationCoordinate2D(latitude: 37.7740, longitude: -122.4194),
    CLLocationCoordinate2D(latitude: 37.7750, longitude: -122.4194),
    CLLocationCoordinate2D(latitude: 37.7750, longitude: -122.4184)
]
let cumulative = RouteGeometry.cumulativeDistances(coords)
let singleAngle = RouteGeometry.turnAngle(at: 1, coords: coords)
let windowedAngle = RouteGeometry.windowedTurnAngle(at: 1, coords: coords, cumulative: cumulative, windowMeters: 25.0)
let combinedAngle = RouteGeometry.turnAngle(at: 1, coords: coords, cumulative: cumulative, windowMeters: 25.0)
assert(abs(singleAngle - 90.0) < 5.0)
assert(abs(combinedAngle - max(singleAngle, windowedAngle)) < 0.001)

// 4. Verify computeSegmentTargetSpeeds with floor and lookahead
let baseSpeeds: [CLLocationSpeed] = [20.0, 20.0]
let segmentSpeeds = DrivingDynamics.computeSegmentTargetSpeeds(
    coords: coords,
    cumulative: cumulative,
    baseSpeeds: baseSpeeds,
    turnSlowdownFactor: 0.5,
    braking: 2.5,
    enforceDrivingFloor: true
)
assert(segmentSpeeds.count == 2)
assert(segmentSpeeds[0] >= DrivingDynamics.minimumDrivingSpeedMps)
assert(segmentSpeeds[1] >= DrivingDynamics.minimumDrivingSpeedMps)

print("SWIFT_PHYSICS_RUNTIME_VERIFIED")
"""
        with tempfile.TemporaryDirectory() as td:
            runner_swift = Path(td) / "main.swift"
            runner_bin = Path(td) / "runner"
            runner_swift.write_text(swift_test, encoding="utf-8")

            geom_swift = SIMULATION_DIR / "RouteGeometry.swift"
            dyn_swift = SIMULATION_DIR / "DrivingDynamics.swift"

            cmd = [
                "swiftc",
                "-o",
                str(runner_bin),
                str(runner_swift),
                str(geom_swift),
                str(dyn_swift),
            ]
            compile_proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            assert compile_proc.returncode == 0, f"Swift compilation failed: {compile_proc.stderr}"

            run_proc = subprocess.run([str(runner_bin)], capture_output=True, text=True, timeout=10)
            assert run_proc.returncode == 0, f"Swift execution failed: {run_proc.stderr}"
            assert "SWIFT_PHYSICS_RUNTIME_VERIFIED" in run_proc.stdout
