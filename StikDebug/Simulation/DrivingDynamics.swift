import CoreLocation

// MARK: - Pure movement dynamics (no state, no side effects)

enum DrivingDynamics {

    // MARK: - Speed ramping

    /// Step speed toward `target` using acceleration or braking, scaled by `dt`.
    static func nextSpeed(
        current: CLLocationSpeed,
        target: CLLocationSpeed,
        acceleration: Double,
        braking: Double,
        dt: TimeInterval
    ) -> CLLocationSpeed {
        if current < target {
            return min(current + acceleration * dt, target)
        } else if current > target {
            return max(current - braking * dt, target)
        }
        return current
    }

    // MARK: - Turn speed reduction

    /// Reduce cruise speed for an upcoming turn.
    /// Sharp turns (angle ≥ 90°) reduce to `factor * cruise`; gradual turns (8°–90°) are proportional.
    static func turnTargetSpeed(
        baseCruise: CLLocationSpeed,
        upcomingTurnAngle: Double,
        factor: Double
    ) -> CLLocationSpeed {
        guard upcomingTurnAngle > 8 else { return baseCruise }
        let normalized = min((upcomingTurnAngle - 8.0) / 82.0, 1.0)
        let reduction  = 1.0 - (1.0 - factor) * normalized
        return baseCruise * reduction
    }

    // MARK: - Speed sanitization

    /// Sanitize user-provided cruise speed input in mph.
    /// Clamps valid inputs to 10.0...120.0 mph; falls back to clamped `fallback` (default 35.0 mph).
    static func sanitizeCruiseSpeedMph(_ input: String, fallback: Double = 35.0) -> Double {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(trimmed), !val.isNaN, !val.isInfinite else {
            return min(max(fallback, 10.0), 120.0)
        }
        return min(max(val, 10.0), 120.0)
    }

    // MARK: - Multi-segment target speed computation with lookahead braking

    /// Computes target speeds for each segment of the route, accounting for curve apices and
    /// lookahead braking deceleration.
    ///
    /// Step 1: Apex target speeds based on single-vertex and 25m windowed curve deflection.
    /// Step 2: Backward kinematics lookahead pass ensuring realistic entry deceleration (v² = v_target² + 2·a·d)
    ///         35–50m prior to every curve or turn.
    static func computeSegmentTargetSpeeds(
        coords: [CLLocationCoordinate2D],
        cumulative: [CLLocationDistance],
        baseSpeeds: [CLLocationSpeed],
        turnSlowdownFactor: Double,
        braking: Double,
        enforceDrivingFloor: Bool
    ) -> [CLLocationSpeed] {
        let segmentCount = max(1, coords.count - 1)
        var speeds = [CLLocationSpeed](repeating: 0, count: segmentCount)

        // Step 1: Compute apex target speeds per segment
        for i in 0..<segmentCount {
            let base = i < baseSpeeds.count ? baseSpeeds[i] : (baseSpeeds.last ?? minimumDrivingSpeedMps)
            let angle: Double
            if coords.count >= 2 {
                let singleAngle = RouteGeometry.turnAngle(at: i + 1, coords: coords)
                let windowed = RouteGeometry.windowedTurnAngle(at: i + 1, coords: coords, cumulative: cumulative, windowMeters: 25.0)
                angle = max(singleAngle, windowed)
            } else {
                angle = 0
            }
            var apex = turnTargetSpeed(baseCruise: base, upcomingTurnAngle: angle, factor: turnSlowdownFactor)
            if enforceDrivingFloor {
                apex = max(apex, minimumDrivingSpeedMps)
            }
            speeds[i] = apex
        }

        // Step 2: Backward Lookahead Braking Pass
        if speeds.count >= 2 {
            for i in stride(from: speeds.count - 2, through: 0, by: -1) {
                let segDist = max(0.5, (i + 1 < cumulative.count ? cumulative[i + 1] - cumulative[i] : 4.0))
                let maxEntrySpeed = sqrt(speeds[i + 1] * speeds[i + 1] + 2.0 * max(0.5, braking) * segDist)
                speeds[i] = min(speeds[i], maxEntrySpeed)
            }
        }

        return speeds
    }

    // MARK: - Jitter

    /// Apply random noise ±`jitterFraction` to `speed` so motion doesn't look robotic.
    static func applyJitter(speed: CLLocationSpeed, jitter: Double) -> CLLocationSpeed {
        guard jitter > 0, speed > 0 else { return speed }
        let delta = speed * jitter * Double.random(in: -1...1)
        return max(0, speed + delta)
    }

    // MARK: - Life360 driving detection helpers

    /// Returns true if the speed is in the range Life360 typically classifies as driving.
    /// Life360 threshold is approximately 7 m/s (15 mph); we target ≥ 8 m/s for headroom.
    static func isDrivingSpeed(_ speedMps: CLLocationSpeed) -> Bool {
        speedMps >= 7.0
    }

    /// Minimum safe cruise speed for the Drive profile so Life360 reliably detects driving.
    /// 7.15 m/s corresponds to 16.0 mph.
    static let minimumDrivingSpeedMps: CLLocationSpeed = 7.15
}
