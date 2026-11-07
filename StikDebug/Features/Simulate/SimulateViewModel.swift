import Foundation
import CoreLocation
import SwiftUI
import MapKit
import Combine

enum RoutePlacementPhase: Equatable {
    case idle
    case pickingStart
    case pickingEnd
    case pickingHold
    case ready
}

@MainActor
final class SimulateViewModel: ObservableObject {

    // MARK: - Route editor state
    @Published var waypoints: [Waypoint] = []
    @Published var routeName: String = "New Route"
    @Published var selectedMode: MovementMode = .drive
    @Published var driveSpeedMph: Double = 38.0
    @Published var customSpeedMph: Double = 30
    @Published var speedMultiplier: Double = 1.0
    @Published var loopEnabled: Bool = false
    @Published var autoParkEnabled: Bool = true
    @Published var mapPosition: MapCameraPosition = .automatic

    @Published var placementPhase: RoutePlacementPhase = .idle
    @Published var placementPrompt: String?
    @Published var startWaypoint: Waypoint?
    @Published var endWaypoint: Waypoint?

    // MARK: - MKDirections route overlay
    @Published var routePolyline: MKPolyline?
    @Published var isCalculatingRoute = false

    // MARK: - Device location
    @Published var userLocation: CLLocationCoordinate2D?

    // MARK: - Playback
    @Published var isPlaying: Bool = false
    @Published var isPreparing: Bool = false
    @Published var isAutoParking: Bool = false
    @Published var autoParkRemainingSeconds: Int = 0
    @Published var isHoldingLocation: Bool = false
    @Published var stats: RouteStats = RouteStats()
    @Published var currentCoordinate: CLLocationCoordinate2D?

    // MARK: - File import
    @Published var showFilePicker = false
    @Published var importError: String?

    // MARK: - Save/load
    @Published var showSaveSheet = false

    // MARK: - Google Map & Search
    @Published var googleMapStyle: GoogleMapStyle = .street
    @Published var cameraTarget: CLLocationCoordinate2D?
    @Published var searchQuery: String = ""
    @Published var searchSuggestions: [PlaceSuggestion] = []
    @Published var isSearching: Bool = false
    @Published var selectedDestinationName: String?
    @Published var savedQuickPins: [PlaceSuggestion] = []

    // MARK: - Drive & Teleport tabs support
    @Published var startSearchQuery: String = ""
    @Published var startSuggestions: [PlaceSuggestion] = []
    @Published var isSearchingStart: Bool = false
    @Published var useCurrentLocationForStart: Bool = true
    @Published var selectedStartName: String = "Current Location"
    @Published var customSpeedText: String = "35"
    @Published var isSpoofKeepAliveActive: Bool = false
    public static let driveSpeedPresetsMph: [Double] = [25, 35, 45, 65]

    private let placeSearchService = PlaceSearchService()
    private var searchTask: Task<Void, Never>?
    private var startSearchTask: Task<Void, Never>?

    let player = RoutePlayer()

    private var routedPlaybackCoordinates: [CLLocationCoordinate2D] = []
    private let deviceLocation = DeviceLocationManager.shared
    private var cancellables = Set<AnyCancellable>()

    var startPinCoordinate: CLLocationCoordinate2D? {
        if selectedMode == .standstill {
            return waypoints.first?.coordinate
        }
        return startWaypoint?.coordinate
    }

    var endPinCoordinate: CLLocationCoordinate2D? {
        guard selectedMode != .standstill else { return nil }
        return endWaypoint?.coordinate
    }

    var canPlay: Bool {
        if selectedMode == .standstill {
            return placementPhase == .ready && waypoints.count == 1
        }
        return placementPhase == .ready && !waypoints.isEmpty
    }

    init() {
        player.$isPlaying.assign(to: &$isPlaying)
        player.$isPreparing.assign(to: &$isPreparing)
        player.$stats.assign(to: &$stats)
        player.$currentCoordinate.assign(to: &$currentCoordinate)
        player.$isAutoParking.assign(to: &$isAutoParking)
        player.$autoParkRemainingSeconds.assign(to: &$autoParkRemainingSeconds)

        LocationSimulator.shared.$isHolding
            .receive(on: DispatchQueue.main)
            .assign(to: &$isHoldingLocation)

        $autoParkEnabled
            .sink { [weak self] enabled in
                self?.player.autoParkEnabled = enabled
            }
            .store(in: &cancellables)

        player.onRouteFinished = { [weak self] in
            self?.selectedMode = .standstill
            self?.placementPhase = .ready
            self?.placementPrompt = nil
        }

        deviceLocation.$coordinate
            .receive(on: DispatchQueue.main)
            .assign(to: &$userLocation)

        savedQuickPins = QuickPinStorage.loadSavedQuickPins()

        Publishers.CombineLatest3(player.$isPlaying, LocationSimulator.shared.$isHolding, SpoofKeepAliveManager.shared.$isActive)
            .receive(on: DispatchQueue.main)
            .map { playing, holding, keepAlive in playing || holding || keepAlive }
            .assign(to: &$isSpoofKeepAliveActive)

        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.triggerSearch(query: query)
            }
            .store(in: &cancellables)

        $startSearchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.triggerStartSearch(query: query)
            }
            .store(in: &cancellables)
    }

    // MARK: - Route placement

    func clearRoute() {
        waypoints = []
        startWaypoint = nil
        endWaypoint = nil
        routePolyline = nil
        routedPlaybackCoordinates = []
        placementPhase = .idle
        placementPrompt = nil
        player.stop()
    }

    func beginNewRoute(for mode: MovementMode) {
        clearRoute()
        if mode == .standstill {
            placementPhase = .pickingHold
            placementPrompt = "Tap map to set hold location"
        } else {
            placementPhase = .pickingStart
            placementPrompt = "Tap map to set start"
        }
    }

    func selectMode(_ mode: MovementMode) {
        selectedMode = mode
        beginNewRoute(for: mode)
    }

    func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        switch placementPhase {
        case .idle, .pickingStart:
            clearRoute()
            if selectedMode == .standstill {
                let hold = Waypoint(coordinate: coordinate, name: "Hold")
                waypoints = [hold]
                startWaypoint = hold
                placementPhase = .ready
                placementPrompt = nil
            } else {
                let start = Waypoint(coordinate: coordinate, name: "Start")
                startWaypoint = start
                waypoints = [start]
                placementPhase = .pickingEnd
                placementPrompt = "Tap map to set destination"
            }

        case .pickingEnd:
            guard let start = startWaypoint else {
                beginNewRoute(for: selectedMode)
                handleMapTap(at: coordinate)
                return
            }
            let end = Waypoint(coordinate: coordinate, name: "End")
            endWaypoint = end
            waypoints = [start, end]
            placementPhase = .ready
            placementPrompt = nil
            Task { await refreshRoutedPolyline() }

        case .pickingHold:
            let hold = Waypoint(coordinate: coordinate, name: "Hold")
            waypoints = [hold]
            startWaypoint = hold
            endWaypoint = nil
            placementPhase = .ready
            placementPrompt = nil

        case .ready:
            beginNewRoute(for: selectedMode)
            handleMapTap(at: coordinate)
        }
    }

    // MARK: - Device location

    func startUserLocationUpdates() {
        deviceLocation.startUpdating()
    }

    func stopUserLocationUpdates() {
        deviceLocation.stopUpdating()
    }

    func requestUserLocationAccess() {
        deviceLocation.requestAuthorizationIfNeeded()
        deviceLocation.startUpdating()
    }

    func useCurrentLocationAsStart() {
        guard let coord = userLocation else {
            requestUserLocationAccess()
            return
        }
        if selectedMode == .standstill {
            beginNewRoute(for: .standstill)
            handleMapTap(at: coord)
        } else {
            beginNewRoute(for: selectedMode)
            handleMapTap(at: coord)
        }
        mapPosition = .camera(MapCamera(centerCoordinate: coord, distance: 1500))
    }

    // MARK: - Prepare and play

    func prepare() async {
        let coords = playbackCoordinates()
        guard !coords.isEmpty else { return }

        var profile = MovementProfile.default(for: selectedMode)
        if selectedMode == .drive {
            profile = .drive(cruiseMph: driveSpeedMph)
        } else if selectedMode == .custom {
            let mps = customSpeedMph * 0.44704
            profile = .custom(speedMps: mps)
        }

        player.autoParkEnabled = autoParkEnabled
        player.waypoints = coords
        player.profile = profile
        player.speedMultiplier = speedMultiplier
        player.loop = loopEnabled

        await player.prepare()
    }

    func instantTeleport(to coordinate: CLLocationCoordinate2D, name: String = "Teleport Pin") {
        let pin = Waypoint(coordinate: coordinate, name: name)
        startWaypoint = pin
        endWaypoint = nil
        waypoints = [pin]
        placementPhase = .ready
        placementPrompt = nil
        routePolyline = nil
        routedPlaybackCoordinates = [coordinate]
        player.teleportAndHold(at: coordinate)
    }

    func selectTeleportTarget(coordinate: CLLocationCoordinate2D, title: String = "Selected Pin") {
        selectedDestinationName = title
        let pin = Waypoint(coordinate: coordinate, name: title)
        startWaypoint = pin
        waypoints = [pin]
        cameraTarget = coordinate
    }

    func restoreRealGPS() {
        player.stop()
        LocationSimulator.shared.clear()
        placementPhase = .idle
        placementPrompt = nil
    }

    // MARK: - Search & Quick Presets

    public enum SearchAction {
        case teleportImmediately
        case setAsDestination
        case setAsStart
    }

    func triggerSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            searchSuggestions = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            guard let self = self else { return }
            let region = self.currentCoordinate != nil ? MKCoordinateRegion(center: self.currentCoordinate!, latitudinalMeters: 50_000, longitudinalMeters: 50_000) : nil
            let results = await self.placeSearchService.search(query: trimmed, region: region)
            guard !Task.isCancelled else { return }
            self.searchSuggestions = results
            self.isSearching = false
        }
    }

    func performSearch() {
        triggerSearch(query: searchQuery)
    }

    func selectSearchSuggestion(_ suggestion: PlaceSuggestion, action: SearchAction) {
        selectedDestinationName = suggestion.title
        switch action {
        case .teleportImmediately:
            instantTeleport(to: suggestion.coordinate, name: suggestion.title)
            cameraTarget = suggestion.coordinate
            searchSuggestions = []
            searchQuery = ""

        case .setAsDestination:
            if startWaypoint == nil {
                let startCoord = currentCoordinate ?? userLocation ?? suggestion.coordinate
                startWaypoint = Waypoint(coordinate: startCoord, name: "Start Location")
            }
            let end = Waypoint(coordinate: suggestion.coordinate, name: suggestion.title)
            endWaypoint = end
            waypoints = [startWaypoint!, end]
            selectedMode = .drive
            placementPhase = .ready
            placementPrompt = nil
            cameraTarget = suggestion.coordinate
            searchSuggestions = []
            searchQuery = ""
            Task { await refreshRoutedPolyline() }

        case .setAsStart:
            let start = Waypoint(coordinate: suggestion.coordinate, name: suggestion.title)
            startWaypoint = start
            endWaypoint = nil
            waypoints = [start]
            placementPhase = .pickingEnd
            placementPrompt = "Tap map to set destination"
            cameraTarget = suggestion.coordinate
            searchSuggestions = []
            searchQuery = ""
        }
    }

    // MARK: - Start search & Drive controls

    func triggerStartSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        startSearchTask?.cancel()

        guard !trimmed.isEmpty else {
            startSuggestions = []
            isSearchingStart = false
            return
        }

        isSearchingStart = true
        startSearchTask = Task { [weak self] in
            guard let self = self else { return }
            let region = self.currentCoordinate != nil ? MKCoordinateRegion(center: self.currentCoordinate!, latitudinalMeters: 50_000, longitudinalMeters: 50_000) : nil
            let results = await self.placeSearchService.search(query: trimmed, region: region)
            guard !Task.isCancelled else { return }
            self.startSuggestions = results
            self.isSearchingStart = false
        }
    }

    func selectStartSuggestion(_ suggestion: PlaceSuggestion) {
        useCurrentLocationForStart = false
        selectedStartName = suggestion.title
        let start = Waypoint(coordinate: suggestion.coordinate, name: suggestion.title)
        startWaypoint = start
        startSearchQuery = suggestion.title
        startSuggestions = []
        cameraTarget = suggestion.coordinate

        if let end = endWaypoint {
            waypoints = [start, end]
            selectedMode = .drive
            placementPhase = .ready
            Task { await refreshRoutedPolyline() }
        } else {
            waypoints = [start]
            placementPhase = .pickingEnd
        }
    }

    func selectCurrentLocationAsStart() {
        useCurrentLocationForStart = true
        selectedStartName = "Current Location"
        startSearchQuery = ""
        startSuggestions = []

        guard let coord = currentCoordinate ?? userLocation else {
            requestUserLocationAccess()
            return
        }

        let start = Waypoint(coordinate: coord, name: "Current Location")
        startWaypoint = start

        if let end = endWaypoint {
            waypoints = [start, end]
            selectedMode = .drive
            placementPhase = .ready
            Task { await refreshRoutedPolyline() }
        } else {
            waypoints = [start]
        }
    }

    func applySpeedPreset(_ mph: Double) {
        let sanitized = DrivingDynamics.sanitizeCruiseSpeedMph(String(mph), fallback: mph)
        driveSpeedMph = sanitized
        customSpeedText = String(Int(driveSpeedMph))
        if isPlaying {
            player.profile = .drive(cruiseMph: driveSpeedMph, useRoadSpeedLimits: false)
        }
    }

    func applyCustomSpeedText(_ text: String) {
        let sanitized = DrivingDynamics.sanitizeCruiseSpeedMph(text, fallback: driveSpeedMph)
        driveSpeedMph = sanitized
        customSpeedText = String(Int(driveSpeedMph))
        if isPlaying {
            player.profile = .drive(cruiseMph: driveSpeedMph, useRoadSpeedLimits: false)
        }
    }

    func saveCurrentQuickPin(title: String, coordinate: CLLocationCoordinate2D) {
        _ = QuickPinStorage.saveQuickPin(title: title, coordinate: coordinate)
        savedQuickPins = QuickPinStorage.loadSavedQuickPins()
    }

    func deleteSavedQuickPin(id: UUID) {
        QuickPinStorage.deleteQuickPin(id: id)
        savedQuickPins = QuickPinStorage.loadSavedQuickPins()
    }

    func loadSavedQuickPins() {
        savedQuickPins = QuickPinStorage.loadSavedQuickPins()
    }

    func playPause() {
        if isPlaying {
            player.pause()
            return
        }

        if selectedMode == .standstill {
            if placementPhase != .ready || waypoints.count != 1 {
                beginNewRoute(for: .standstill)
                return
            }
            Task {
                await prepare()
                player.play()
            }
            return
        }

        guard placementPhase == .ready else { return }
        Task {
            await prepare()
            player.play()
        }
    }

    func stop() {
        player.stop()
    }

    func scrub(to progress: Double) {
        player.scrub(to: progress)
    }

    // MARK: - GPX import

    func handleImport(url: URL) {
        do {
            let coords = try GPXImporter.parse(url: url)
            waypoints = coords.map { Waypoint(coordinate: $0) }
            finalizeLoadedRoute()
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Load from library

    func load(_ route: SavedRoute) {
        routeName = route.name
        selectedMode = route.mode
        waypoints = route.waypoints
        finalizeLoadedRoute()
    }

    private func finalizeLoadedRoute() {
        startWaypoint = waypoints.first
        endWaypoint = waypoints.count >= 2 ? waypoints.last : nil
        routedPlaybackCoordinates = waypoints.map(\.coordinate)
        placementPhase = .ready
        placementPrompt = nil

        if selectedMode == .standstill {
            if waypoints.count > 1 {
                waypoints = [waypoints[0]]
                startWaypoint = waypoints.first
                endWaypoint = nil
            }
            routedPlaybackCoordinates = waypoints.map(\.coordinate)
            return
        }

        if waypoints.count >= 2 {
            Task { await refreshRoutedPolyline() }
        } else if !waypoints.isEmpty {
            var mutable = waypoints.map(\.coordinate)
            routePolyline = MKPolyline(coordinates: &mutable, count: mutable.count)
        }
    }

    // MARK: - Save to library

    func saveToLibrary() {
        var route = SavedRoute(
            name: routeName.isEmpty ? "Unnamed Route" : routeName,
            mode: selectedMode,
            waypoints: waypoints,
            stops: []
        )
        if selectedMode == .custom {
            route.profileOverride = ProfileOverride(
                cruiseSpeedMps: customSpeedMph * 0.44704,
                speedMultiplier: speedMultiplier,
                loop: loopEnabled
            )
        }
        RouteStore.shared.save(route)
    }

    // MARK: - Routed polyline

    private func playbackCoordinates() -> [CLLocationCoordinate2D] {
        if !routedPlaybackCoordinates.isEmpty {
            return routedPlaybackCoordinates
        }
        return waypoints.map(\.coordinate)
    }

    func refreshRoutedPolyline() async {
        routePolyline = nil
        routedPlaybackCoordinates = []

        guard selectedMode != .standstill else { return }

        if waypoints.count < 2 {
            if !waypoints.isEmpty {
                var mutable = waypoints.map(\.coordinate)
                routePolyline = MKPolyline(coordinates: &mutable, count: mutable.count)
                routedPlaybackCoordinates = mutable
            }
            return
        }

        guard let start = startWaypoint?.coordinate ?? waypoints.first?.coordinate,
              let end = endWaypoint?.coordinate ?? waypoints.last?.coordinate else {
            return
        }

        var fallback = [start, end]
        routePolyline = MKPolyline(coordinates: &fallback, count: fallback.count)
        routedPlaybackCoordinates = fallback

        isCalculatingRoute = true
        defer { isCalculatingRoute = false }

        let request = MKDirections.Request()
        if #available(iOS 26.0, *) {
            request.source = MKMapItem(
                location: CLLocation(latitude: start.latitude, longitude: start.longitude),
                address: nil
            )
            request.destination = MKMapItem(
                location: CLLocation(latitude: end.latitude, longitude: end.longitude),
                address: nil
            )
        } else {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        }
        request.transportType = transportType(for: selectedMode)

        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else {
            return
        }

        routePolyline = route.polyline
        routedPlaybackCoordinates = coordinates(from: route.polyline)
    }

    private func transportType(for mode: MovementMode) -> MKDirectionsTransportType {
        switch mode {
        case .walk, .bike, .custom:
            return .walking
        case .drive:
            return .automobile
        case .bus:
            return .transit
        case .standstill:
            return .walking
        }
    }

    private func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }
}
