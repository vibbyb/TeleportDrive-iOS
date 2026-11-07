import Foundation
import CoreLocation

// MARK: - Typed error wrapper around the C bridge's Int32 status codes

enum LocationSimulatorError: LocalizedError {
    case invalidIP
    case pairingFileUnreadable
    case providerCreateFailed
    case remoteServerFailed
    case sessionCreateFailed
    case locationSetFailed
    case clearFailed
    case unknown(Int32)

    init(statusCode: Int32) {
        switch statusCode {
        case LocationSimulationStatus.invalidIP:          self = .invalidIP
        case LocationSimulationStatus.pairingRead:        self = .pairingFileUnreadable
        case LocationSimulationStatus.providerCreate:     self = .providerCreateFailed
        case LocationSimulationStatus.remoteServer:       self = .remoteServerFailed
        case LocationSimulationStatus.locationSimulation: self = .sessionCreateFailed
        case LocationSimulationStatus.locationSet:        self = .locationSetFailed
        case LocationSimulationStatus.locationClear:      self = .clearFailed
        default:                                          self = .unknown(statusCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidIP:              return "Device IP address is invalid. Check Settings."
        case .pairingFileUnreadable:  return "Pairing file is missing or unreadable. Re-import it."
        case .providerCreateFailed:   return "Could not create the RSD tunnel. Is LocalDevVPN connected?"
        case .remoteServerFailed:     return "Remote server connection failed. Wake the device and try again."
        case .sessionCreateFailed:    return "Location simulation session could not be created."
        case .locationSetFailed:      return "Failed to set the simulated location. Session was reset."
        case .clearFailed:            return "Failed to clear the simulated location."
        case .unknown(let code):      return "Location simulation error (code \(code))."
        }
    }
}

// MARK: - LocationSimulator
//
// Thread-safe wrapper over the C bridge.
// All bridge calls are dispatched on LocationSimulationCommandQueue.shared (serial).

final class LocationSimulator: ObservableObject {
    static let shared = LocationSimulator()

    @Published private(set) var isHolding = false
    @Published private(set) var lastError: LocationSimulatorError?

    private let stateLock = NSLock()
    private var sessionGeneration: UInt64 = 0
    private var isWriteInFlight: Bool = false
    private(set) var holdAnchorCoordinate: CLLocationCoordinate2D?
    let holdIntervalSeconds: TimeInterval = 1.0

    private var holdTimer: DispatchSourceTimer?
    private var holdCoordinate: CLLocationCoordinate2D?

    private init() {}

    // MARK: - Set location (called each tick by RoutePlayer)

    @discardableResult
    func setLocation(_ coordinate: CLLocationCoordinate2D, coalesceIfBusy: Bool = false) async -> Result<Void, LocationSimulatorError> {
        let currentGeneration: UInt64
        stateLock.lock()
        if coalesceIfBusy && isWriteInFlight {
            stateLock.unlock()
            return .success(())
        }
        isWriteInFlight = true
        currentGeneration = sessionGeneration
        stateLock.unlock()

        return await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(.clearFailed))
                    return
                }

                self.stateLock.lock()
                let stale = (self.sessionGeneration != currentGeneration)
                if stale {
                    self.isWriteInFlight = false
                    self.stateLock.unlock()
                    continuation.resume(returning: .success(()))
                    return
                }
                self.stateLock.unlock()

                let code = simulate_location(
                    DeviceConnectionContext.targetIPAddress,
                    coordinate.latitude,
                    coordinate.longitude,
                    PairingFileStore.prepareURL().path
                )

                self.stateLock.lock()
                self.isWriteInFlight = false
                self.stateLock.unlock()

                if code == LocationSimulationStatus.ok {
                    Task { @MainActor in self.lastError = nil }
                    continuation.resume(returning: .success(()))
                } else {
                    let error = LocationSimulatorError(statusCode: code)
                    Task { @MainActor in self.lastError = error }
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    // MARK: - Clear

    func clear() {
        stateLock.lock()
        sessionGeneration &+= 1
        stateLock.unlock()

        stopHold(deactivateKeepAlive: true)

        LocationSimulationCommandQueue.shared.async {
            _ = clear_simulated_location()
        }
    }

    // MARK: - Hold / keep-alive
    //
    // Keeps re-sending the last coordinate every 1.0 second so iOS does not
    // revert to the real GPS while the player is paused or at end-of-route.

    func startHold(at coordinate: CLLocationCoordinate2D, jitterMeters: Double = 0.35) {
        stopHold(deactivateKeepAlive: false)
        holdCoordinate = coordinate
        holdAnchorCoordinate = coordinate
        if Thread.isMainThread {
            self.isHolding = true
        } else {
            DispatchQueue.main.async {
                self.isHolding = true
            }
        }
        SpoofKeepAliveManager.shared.activate()

        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coordinate.latitude,
                coordinate.longitude,
                PairingFileStore.prepareURL().path
            )
        }

        let source = DispatchSource.makeTimerSource(queue: LocationSimulationCommandQueue.shared)
        source.schedule(deadline: .now() + holdIntervalSeconds, repeating: holdIntervalSeconds, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self,
                  let anchor = self.holdAnchorCoordinate else { return }
            let current = self.holdCoordinate ?? anchor

            let cosLat = max(0.1, cos(anchor.latitude * .pi / 180.0))
            let metersPerDegreeLat = 111_111.0
            let metersPerDegreeLon = 111_111.0 * cosLat

            let angle = Double.random(in: 0 ..< (2.0 * .pi))
            let stepMeters = 0.12
            let stepX = cos(angle) * stepMeters
            let stepY = sin(angle) * stepMeters

            var currentOffsetX = (current.longitude - anchor.longitude) * metersPerDegreeLon
            var currentOffsetY = (current.latitude - anchor.latitude) * metersPerDegreeLat

            currentOffsetX += stepX
            currentOffsetY += stepY

            let totalDist = hypot(currentOffsetX, currentOffsetY)
            if totalDist > jitterMeters && totalDist > 0 {
                let scale = jitterMeters / totalDist
                currentOffsetX *= scale
                currentOffsetY *= scale
            }

            let nextLat = anchor.latitude + (currentOffsetY / metersPerDegreeLat)
            let nextLon = anchor.longitude + (currentOffsetX / metersPerDegreeLon)
            let nextCoord = CLLocationCoordinate2D(latitude: nextLat, longitude: nextLon)
            self.holdCoordinate = nextCoord

            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                nextLat,
                nextLon,
                PairingFileStore.prepareURL().path
            )
            if code == LocationSimulationStatus.ok {
                Task { @MainActor in self.lastError = nil }
            }
        }
        self.holdTimer = source
        source.resume()
    }

    func stopHold(deactivateKeepAlive: Bool = false) {
        holdTimer?.cancel()
        holdTimer = nil
        holdCoordinate = nil
        holdAnchorCoordinate = nil
        if Thread.isMainThread {
            self.isHolding = false
        } else {
            DispatchQueue.main.async {
                self.isHolding = false
            }
        }
        if deactivateKeepAlive {
            SpoofKeepAliveManager.shared.deactivate()
        }
    }

    func refreshHoldIfNeeded() {
        guard isHolding, let coord = holdAnchorCoordinate ?? holdCoordinate else { return }
        LocationSimulationCommandQueue.shared.async { [weak self] in
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coord.latitude,
                coord.longitude,
                PairingFileStore.prepareURL().path
            )
            if code == LocationSimulationStatus.ok {
                Task { @MainActor [weak self] in
                    self?.lastError = nil
                }
            }
        }
    }
}
