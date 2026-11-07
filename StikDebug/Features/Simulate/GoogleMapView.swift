import SwiftUI
import MapKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Google Map Style

public enum GoogleMapStyle: String, CaseIterable, Identifiable {
    case street = "Street"
    case hybrid = "Satellite"
    case terrain = "Terrain"

    public var id: String { rawValue }

    public var lyrsCode: String {
        switch self {
        case .street: return "m"
        case .hybrid: return "y"
        case .terrain: return "p"
        }
    }
}

// MARK: - Google Maps Tile Overlay

public final class GoogleMapsTileOverlay: MKTileOverlay {
    public let style: GoogleMapStyle

    public init(style: GoogleMapStyle) {
        self.style = style
        super.init(urlTemplate: nil)
        self.canReplaceMapContent = true
        self.tileSize = CGSize(width: 256, height: 256)
        self.maximumZ = 21
    }

    public override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let server = (path.x + path.y) & 3
        let urlString = "https://mt\(server).google.com/vt/lyrs=\(style.lyrsCode)&hl=en&x=\(path.x)&y=\(path.y)&z=\(path.z)&scale=2"
        return URL(string: urlString)!
    }
}

// MARK: - Marker Types & Annotations

public enum MapMarkerType: Hashable {
    case start
    case end
    case vehicle(isHolding: Bool)
}

public final class MapMarkerAnnotation: NSObject, MKAnnotation {
    public dynamic var coordinate: CLLocationCoordinate2D
    public var title: String?
    public var subtitle: String?
    public var markerType: MapMarkerType

    public init(
        coordinate: CLLocationCoordinate2D,
        title: String?,
        subtitle: String? = nil,
        markerType: MapMarkerType
    ) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.markerType = markerType
    }
}

// MARK: - GoogleMapView UIViewRepresentable

#if canImport(UIKit)
public struct GoogleMapView: UIViewRepresentable {
    public var mapStyle: GoogleMapStyle
    public var startCoordinate: CLLocationCoordinate2D?
    public var endCoordinate: CLLocationCoordinate2D?
    public var currentCoordinate: CLLocationCoordinate2D?
    public var isHolding: Bool
    public var routePolyline: MKPolyline?
    @Binding public var cameraTarget: CLLocationCoordinate2D?
    public var onMapTap: (CLLocationCoordinate2D) -> Void
    public var onLongPress: ((CLLocationCoordinate2D) -> Void)?

    public init(
        mapStyle: GoogleMapStyle = .street,
        startCoordinate: CLLocationCoordinate2D? = nil,
        endCoordinate: CLLocationCoordinate2D? = nil,
        currentCoordinate: CLLocationCoordinate2D? = nil,
        isHolding: Bool = false,
        routePolyline: MKPolyline? = nil,
        cameraTarget: Binding<CLLocationCoordinate2D?> = .constant(nil),
        onMapTap: @escaping (CLLocationCoordinate2D) -> Void = { _ in },
        onLongPress: ((CLLocationCoordinate2D) -> Void)? = nil
    ) {
        self.onLongPress = onLongPress
        self.mapStyle = mapStyle
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.currentCoordinate = currentCoordinate
        self.isHolding = isHolding
        self.routePolyline = routePolyline
        self._cameraTarget = cameraTarget
        self.onMapTap = onMapTap
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true

        // Add Google Maps Tile Overlay
        let overlay = GoogleMapsTileOverlay(style: mapStyle)
        context.coordinator.currentTileOverlay = overlay
        mapView.addOverlay(overlay, level: .aboveLabels)

        // Tap gesture for pin placement
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        mapView.addGestureRecognizer(tap)

        if onLongPress != nil {
            let longPress = UILongPressGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            tap.require(toFail: longPress)
            mapView.addGestureRecognizer(longPress)
        }

        return mapView
    }

    public func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // 1. Update Tile Overlay if style changed
        if context.coordinator.currentTileOverlay?.style != mapStyle {
            if let old = context.coordinator.currentTileOverlay {
                mapView.removeOverlay(old)
            }
            let newOverlay = GoogleMapsTileOverlay(style: mapStyle)
            context.coordinator.currentTileOverlay = newOverlay
            mapView.insertOverlay(newOverlay, at: 0, level: .aboveLabels)
        }

        // 2. Update Polyline Overlay
        let existingPolylines = mapView.overlays.compactMap { $0 as? MKPolyline }
        if let newPolyline = routePolyline {
            if !existingPolylines.contains(where: { $0 === newPolyline }) {
                mapView.removeOverlays(existingPolylines)
                mapView.addOverlay(newPolyline, level: .aboveRoads)
            }
        } else if !existingPolylines.isEmpty {
            mapView.removeOverlays(existingPolylines)
        }

        // 3. Update Annotations
        context.coordinator.syncAnnotations(
            mapView: mapView,
            startCoord: startCoordinate,
            endCoord: endCoordinate,
            currentCoord: currentCoordinate,
            isHolding: isHolding
        )

        // 4. Update Camera Target if requested
        if let target = cameraTarget {
            let region = MKCoordinateRegion(center: target, latitudinalMeters: 1000, longitudinalMeters: 1000)
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                self.cameraTarget = nil
            }
        }
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: GoogleMapView
        var currentTileOverlay: GoogleMapsTileOverlay?

        var startAnnotation: MapMarkerAnnotation?
        var endAnnotation: MapMarkerAnnotation?
        var vehicleAnnotation: MapMarkerAnnotation?

        init(_ parent: GoogleMapView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onMapTap(coord)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let handler = parent.onLongPress,
                  let mapView = gesture.view as? MKMapView else { return }
            let coord = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            handler(coord)
        }

        func syncAnnotations(
            mapView: MKMapView,
            startCoord: CLLocationCoordinate2D?,
            endCoord: CLLocationCoordinate2D?,
            currentCoord: CLLocationCoordinate2D?,
            isHolding: Bool
        ) {
            // Start Annotation
            if let coord = startCoord {
                if let existing = startAnnotation {
                    existing.coordinate = coord
                } else {
                    let a = MapMarkerAnnotation(coordinate: coord, title: "Start", markerType: .start)
                    startAnnotation = a
                    mapView.addAnnotation(a)
                }
            } else if let existing = startAnnotation {
                mapView.removeAnnotation(existing)
                startAnnotation = nil
            }

            // End Annotation
            if let coord = endCoord {
                if let existing = endAnnotation {
                    existing.coordinate = coord
                } else {
                    let a = MapMarkerAnnotation(coordinate: coord, title: "Destination", markerType: .end)
                    endAnnotation = a
                    mapView.addAnnotation(a)
                }
            } else if let existing = endAnnotation {
                mapView.removeAnnotation(existing)
                endAnnotation = nil
            }

            // Vehicle / Live Spoofed Annotation
            if let coord = currentCoord {
                let markerType: MapMarkerType = .vehicle(isHolding: isHolding)
                let title = isHolding ? "Holding Location" : "Spoofed Vehicle"
                if let existing = vehicleAnnotation {
                    existing.coordinate = coord
                    existing.title = title
                    existing.markerType = markerType
                    if let view = mapView.view(for: existing) as? MKMarkerAnnotationView {
                        configureMarker(view, for: markerType)
                    }
                } else {
                    let a = MapMarkerAnnotation(coordinate: coord, title: title, markerType: markerType)
                    vehicleAnnotation = a
                    mapView.addAnnotation(a)
                }
            } else if let existing = vehicleAnnotation {
                mapView.removeAnnotation(existing)
                vehicleAnnotation = nil
            }
        }

        private func configureMarker(_ view: MKMarkerAnnotationView, for type: MapMarkerType) {
            switch type {
            case .start:
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: "flag.fill")
                view.displayPriority = .required
            case .end:
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "mappin")
                view.displayPriority = .required
            case .vehicle(let isHolding):
                view.markerTintColor = isHolding ? .systemOrange : .systemBlue
                view.glyphImage = UIImage(systemName: isHolding ? "pause.fill" : "car.fill")
                view.displayPriority = .required
            }
        }

        // MARK: - MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 5.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let marker = annotation as? MapMarkerAnnotation else { return nil }

            let identifier = "MapMarkerAnnotationView"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: marker, reuseIdentifier: identifier)

            view.annotation = marker
            view.canShowCallout = true
            configureMarker(view, for: marker.markerType)
            return view
        }
    }
}
#endif
