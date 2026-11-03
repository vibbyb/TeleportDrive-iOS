import CoreLocation
import XCTest
@testable import StikDebug

final class RouteSimTests: XCTestCase {
    func testRouteGeometryBearing() {
        let a = CLLocationCoordinate2D(latitude: 27.9472, longitude: -82.4586)
        let b = CLLocationCoordinate2D(latitude: 27.9550, longitude: -82.4500)
        let bearing = RouteGeometry.bearing(from: a, to: b)
        XCTAssertGreaterThan(bearing, 0)
        XCTAssertLessThan(bearing, 360)
    }

    func testDensifyIncreasesPoints() {
        let coords = [
            CLLocationCoordinate2D(latitude: 27.9472, longitude: -82.4586),
            CLLocationCoordinate2D(latitude: 27.9600, longitude: -82.4500)
        ]
        let dense = RouteGeometry.densify(coords, maxStepMeters: 20)
        XCTAssertGreaterThan(dense.count, 2)
    }

    func testMovementProfileDefaults() {
        let drive = MovementProfile.drive
        XCTAssertGreaterThanOrEqual(drive.cruiseSpeed, DrivingDynamics.minimumDrivingSpeedMps)
    }

    @MainActor
    func testStandstillProfileHasZeroSpeed() {
        let profile = MovementProfile.standstill
        XCTAssertEqual(profile.cruiseSpeed, 0)
        XCTAssertEqual(profile.maxSpeed, 0)
        XCTAssertEqual(profile.mode, .standstill)
    }

    @MainActor
    func testBeginNewRouteEntersPickingHoldForStandstill() {
        let vm = SimulateViewModel()
        vm.selectMode(.standstill)
        XCTAssertEqual(vm.placementPhase, .pickingHold)
        XCTAssertEqual(vm.placementPrompt, "Tap map to set hold location")
        XCTAssertTrue(vm.waypoints.isEmpty)
    }

    @MainActor
    func testMapTapInStandstillSetsSingleWaypoint() {
        let vm = SimulateViewModel()
        vm.selectMode(.standstill)
        let coord = CLLocationCoordinate2D(latitude: 27.95, longitude: -82.45)
        vm.handleMapTap(at: coord)
        XCTAssertEqual(vm.placementPhase, .ready)
        XCTAssertEqual(vm.waypoints.count, 1)
        XCTAssertTrue(vm.canPlay)
    }

    @MainActor
    func testMovementModeTapSetsStartThenEnd() {
        let vm = SimulateViewModel()
        vm.selectMode(.drive)
        let start = CLLocationCoordinate2D(latitude: 27.94, longitude: -82.46)
        let end = CLLocationCoordinate2D(latitude: 27.96, longitude: -82.44)
        vm.handleMapTap(at: start)
        XCTAssertEqual(vm.placementPhase, .pickingEnd)
        XCTAssertEqual(vm.waypoints.count, 1)
        vm.handleMapTap(at: end)
        XCTAssertEqual(vm.placementPhase, .ready)
        XCTAssertEqual(vm.waypoints.count, 2)
    }

    func testCustomDriveSpeedClampingAndValues() {
        let p45 = MovementProfile.drive(cruiseMph: 45.0)
        XCTAssertEqual(p45.mode, .drive)
        XCTAssertEqual(p45.cruiseSpeed, 45.0 * 0.44704, accuracy: 0.001)
        XCTAssertFalse(p45.useRoadSpeedLimits)
        XCTAssertEqual(p45.acceleration, 2.0)
        XCTAssertEqual(p45.braking, 2.5)

        // Lower clamp
        let pLow = MovementProfile.drive(cruiseMph: 2.0)
        XCTAssertEqual(pLow.cruiseSpeed, 5.0 * 0.44704, accuracy: 0.001)

        // Upper clamp
        let pHigh = MovementProfile.drive(cruiseMph: 150.0)
        XCTAssertEqual(pHigh.cruiseSpeed, 120.0 * 0.44704, accuracy: 0.001)
    }

    func testPairingFileStorePreparedURL() {
        let url = PairingFileStore.prepareURL()
        XCTAssertTrue(url.path.contains("rp_pairing_file.plist"))
        _ = PairingFileStore.hasPairingFile
    }

    @MainActor
    func testRoutePlayerAutoParkDefaultsAndTeleport() {
        let player = RoutePlayer()
        XCTAssertEqual(player.autoParkDurationSeconds, 540)
        XCTAssertTrue(player.autoParkEnabled)
        XCTAssertFalse(player.isAutoParking)
        XCTAssertEqual(player.autoParkRemainingSeconds, 0)

        let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        player.teleportAndHold(at: coord)
        XCTAssertEqual(player.currentCoordinate?.latitude, coord.latitude)
        XCTAssertEqual(player.currentCoordinate?.longitude, coord.longitude)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.stats.speedMps, 0)
    }

    @MainActor
    func testSimulateViewModelDriveSpeedAndAutoPark() {
        let vm = SimulateViewModel()
        XCTAssertEqual(vm.driveSpeedMph, 38.0)
        XCTAssertTrue(vm.autoParkEnabled)
        XCTAssertFalse(vm.isAutoParking)
        XCTAssertEqual(vm.autoParkRemainingSeconds, 0)

        let target = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        vm.instantTeleport(to: target, name: "Hollywood")
        XCTAssertEqual(vm.startWaypoint?.name, "Hollywood")
        XCTAssertEqual(vm.waypoints.count, 1)
        XCTAssertEqual(vm.placementPhase, .ready)
        XCTAssertEqual(vm.player.currentCoordinate?.latitude, target.latitude)

        vm.restoreRealGPS()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.placementPhase, .idle)
    }

    // MARK: - Chunk 3: PlaceSearchService & Google Maps Tests

    func testPlaceSearchCoordinateParser() {
        // Valid standard comma-separated
        let c1 = PlaceSearchService.parseCoordinate(from: "37.7749, -122.4194")
        XCTAssertNotNil(c1)
        XCTAssertEqual(c1!.latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(c1!.longitude, -122.4194, accuracy: 0.0001)

        // Valid whitespace-separated
        let c2 = PlaceSearchService.parseCoordinate(from: "40.7580 -73.9855")
        XCTAssertNotNil(c2)
        XCTAssertEqual(c2!.latitude, 40.7580, accuracy: 0.0001)
        XCTAssertEqual(c2!.longitude, -73.9855, accuracy: 0.0001)

        // Valid with extra spaces
        let c3 = PlaceSearchService.parseCoordinate(from: "  25.7907 ,   -80.1300  ")
        XCTAssertNotNil(c3)
        XCTAssertEqual(c3!.latitude, 25.7907, accuracy: 0.0001)
        XCTAssertEqual(c3!.longitude, -80.1300, accuracy: 0.0001)

        // Invalid bounds
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: "95.0, -122.4194"))
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: "-95.0, -122.4194"))
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: "37.7749, 185.0"))
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: "37.7749, -185.0"))

        // Malformed strings
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: "Golden Gate Bridge"))
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: ""))
        XCTAssertNil(PlaceSearchService.parseCoordinate(from: "37.7749"))
    }

    func testPlaceSearchMapsURLExtraction() {
        // Pattern 1: @lat,lon in URL
        let url1 = "https://www.google.com/maps/@37.774900,-122.419400,16z"
        let coord1 = PlaceSearchService.extractCoordinate(fromURLString: url1)
        XCTAssertNotNil(coord1)
        XCTAssertEqual(coord1!.latitude, 37.7749, accuracy: 0.001)
        XCTAssertEqual(coord1!.longitude, -122.4194, accuracy: 0.001)

        // Pattern 2: ?q=lat,lon in URL
        let url2 = "https://maps.google.com/?q=40.7580,-73.9855"
        let coord2 = PlaceSearchService.extractCoordinate(fromURLString: url2)
        XCTAssertNotNil(coord2)
        XCTAssertEqual(coord2!.latitude, 40.7580, accuracy: 0.001)
        XCTAssertEqual(coord2!.longitude, -73.9855, accuracy: 0.001)

        // Pattern 3: Apple Maps ?ll=lat,lon
        let url3 = "https://maps.apple.com/?ll=37.8199,-122.4783&q=Pin"
        let coord3 = PlaceSearchService.extractCoordinate(fromURLString: url3)
        XCTAssertNotNil(coord3)
        XCTAssertEqual(coord3!.latitude, 37.8199, accuracy: 0.001)
        XCTAssertEqual(coord3!.longitude, -122.4783, accuracy: 0.001)

        // Pattern 4: !3dlat!4dlon protobuf
        let url4 = "https://www.google.com/maps/place/Data/@37.7749,-122.4194,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d37.7749!4d-122.4194"
        let coord4 = PlaceSearchService.extractCoordinate(fromURLString: url4)
        XCTAssertNotNil(coord4)
        XCTAssertEqual(coord4!.latitude, 37.7749, accuracy: 0.001)
        XCTAssertEqual(coord4!.longitude, -122.4194, accuracy: 0.001)

        // Non-maps URL
        let urlNon = "https://example.com/search?q=something"
        XCTAssertNil(PlaceSearchService.extractCoordinate(fromURLString: urlNon))
    }

    func testPlacePresetsAndQuickPins() {
        XCTAssertGreaterThanOrEqual(PlaceSuggestion.presets.count, 8)

        let applePark = PlaceSuggestion.presets.first(where: { $0.title == "Apple Park" })
        XCTAssertNotNil(applePark)
        XCTAssertEqual(applePark!.coordinate.latitude, 37.3346, accuracy: 0.001)
        XCTAssertEqual(applePark!.coordinate.longitude, -122.0090, accuracy: 0.001)
        XCTAssertTrue(applePark!.isPreset)

        let timesSquare = PlaceSuggestion.presets.first(where: { $0.title == "Times Square" })
        XCTAssertNotNil(timesSquare)
        XCTAssertEqual(timesSquare!.coordinate.latitude, 40.7580, accuracy: 0.001)
        XCTAssertEqual(timesSquare!.coordinate.longitude, -73.9855, accuracy: 0.001)

        // QuickPin storage
        let coord = CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)
        let pin = QuickPinStorage.saveQuickPin(title: "Dallas Hub", coordinate: coord)
        let loaded = QuickPinStorage.loadSavedQuickPins()
        XCTAssertTrue(loaded.contains(where: { $0.title == "Dallas Hub" }))

        QuickPinStorage.deleteQuickPin(id: pin.id)
        let reloaded = QuickPinStorage.loadSavedQuickPins()
        XCTAssertFalse(reloaded.contains(where: { $0.id == pin.id }))
    }

    func testGoogleMapsTileOverlayURLs() {
        let streetOverlay = GoogleMapsTileOverlay(style: .street)
        XCTAssertEqual(streetOverlay.style.lyrsCode, "m")
        XCTAssertEqual(streetOverlay.tileSize, CGSize(width: 256, height: 256))
        XCTAssertEqual(streetOverlay.maximumZ, 21)
        XCTAssertTrue(streetOverlay.canReplaceMapContent)

        let path = MKTileOverlayPath(x: 10, y: 20, z: 6, contentScaleFactor: 2.0)
        let urlStreet = streetOverlay.url(forTilePath: path)
        XCTAssertTrue(urlStreet.absoluteString.contains("lyrs=m"))
        XCTAssertTrue(urlStreet.absoluteString.contains("x=10"))
        XCTAssertTrue(urlStreet.absoluteString.contains("y=20"))
        XCTAssertTrue(urlStreet.absoluteString.contains("z=6"))
        XCTAssertTrue(urlStreet.absoluteString.contains("scale=2"))

        let hybridOverlay = GoogleMapsTileOverlay(style: .hybrid)
        XCTAssertEqual(hybridOverlay.style.lyrsCode, "y")
        let urlHybrid = hybridOverlay.url(forTilePath: path)
        XCTAssertTrue(urlHybrid.absoluteString.contains("lyrs=y"))

        let terrainOverlay = GoogleMapsTileOverlay(style: .terrain)
        XCTAssertEqual(terrainOverlay.style.lyrsCode, "p")
        let urlTerrain = terrainOverlay.url(forTilePath: path)
        XCTAssertTrue(urlTerrain.absoluteString.contains("lyrs=p"))
    }

    @MainActor
    func testSimulateViewModelSearchActions() {
        let vm = SimulateViewModel()
        let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let suggestion = PlaceSuggestion(title: "San Francisco", subtitle: "California", coordinate: coord)

        // Action 1: Instant Teleport
        vm.selectSearchSuggestion(suggestion, action: .teleportImmediately)
        XCTAssertEqual(vm.startWaypoint?.coordinate.latitude, coord.latitude)
        XCTAssertEqual(vm.startWaypoint?.name, "San Francisco")
        XCTAssertEqual(vm.placementPhase, .ready)
        XCTAssertEqual(vm.cameraTarget?.latitude, coord.latitude)
        XCTAssertTrue(vm.searchSuggestions.isEmpty)

        // Action 2: Set as Start
        let startCoord = CLLocationCoordinate2D(latitude: 37.3346, longitude: -122.0090)
        let startSug = PlaceSuggestion(title: "Apple Park", subtitle: "Cupertino", coordinate: startCoord)
        vm.selectSearchSuggestion(startSug, action: .setAsStart)
        XCTAssertEqual(vm.startWaypoint?.name, "Apple Park")
        XCTAssertEqual(vm.placementPhase, .pickingEnd)
        XCTAssertNil(vm.endWaypoint)

        // Action 3: Set as Destination
        let endCoord = CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783)
        let endSug = PlaceSuggestion(title: "Golden Gate", subtitle: "SF", coordinate: endCoord)
        vm.selectSearchSuggestion(endSug, action: .setAsDestination)
        XCTAssertEqual(vm.endWaypoint?.name, "Golden Gate")
        XCTAssertEqual(vm.selectedMode, .drive)
        XCTAssertEqual(vm.waypoints.count, 2)
        XCTAssertEqual(vm.placementPhase, .ready)
    }
}
