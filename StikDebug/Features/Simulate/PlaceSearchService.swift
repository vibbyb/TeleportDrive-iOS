import Foundation
import CoreLocation
import MapKit

// MARK: - Place Suggestion

public struct PlaceSuggestion: Identifiable, Equatable, Codable {
    public let id: UUID
    public let title: String
    public let subtitle: String
    public let latitude: Double
    public let longitude: Double
    public let isPreset: Bool

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        coordinate: CLLocationCoordinate2D,
        isPreset: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.isPreset = isPreset
    }

    public static func == (lhs: PlaceSuggestion, rhs: PlaceSuggestion) -> Bool {
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        abs(lhs.latitude - rhs.latitude) < 0.00001 &&
        abs(lhs.longitude - rhs.longitude) < 0.00001
    }

    // MARK: - Built-in Presets

    public static let presets: [PlaceSuggestion] = [
        PlaceSuggestion(
            title: "Apple Park",
            subtitle: "Cupertino, CA",
            coordinate: CLLocationCoordinate2D(latitude: 37.3346, longitude: -122.0090),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Times Square",
            subtitle: "New York, NY",
            coordinate: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Golden Gate Bridge",
            subtitle: "San Francisco, CA",
            coordinate: CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Miami Beach",
            subtitle: "Miami Beach, FL",
            coordinate: CLLocationCoordinate2D(latitude: 25.7907, longitude: -80.1300),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Downtown Chicago",
            subtitle: "Chicago, IL",
            coordinate: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Tokyo Tower",
            subtitle: "Tokyo, Japan",
            coordinate: CLLocationCoordinate2D(latitude: 35.6586, longitude: 139.7454),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Eiffel Tower",
            subtitle: "Paris, France",
            coordinate: CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945),
            isPreset: true
        ),
        PlaceSuggestion(
            title: "Big Ben",
            subtitle: "London, UK",
            coordinate: CLLocationCoordinate2D(latitude: 51.5007, longitude: -0.1246),
            isPreset: true
        )
    ]
}

// MARK: - User Defaults Storage for Quick Pins

public enum QuickPinStorage {
    private static let storageKey = "teleportdrive.savedQuickPins"

    public static func loadSavedQuickPins() -> [PlaceSuggestion] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([PlaceSuggestion].self, from: data) else {
            return []
        }
        return list
    }

    public static func saveQuickPin(title: String, subtitle: String = "Saved Pin", coordinate: CLLocationCoordinate2D) -> PlaceSuggestion {
        var current = loadSavedQuickPins()
        let newPin = PlaceSuggestion(title: title, subtitle: subtitle, coordinate: coordinate, isPreset: false)
        current.removeAll { $0 == newPin }
        current.insert(newPin, at: 0)
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        return newPin
    }

    public static func deleteQuickPin(id: UUID) {
        var current = loadSavedQuickPins()
        current.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Place Search Service

public final class PlaceSearchService {
    public init() {}

    // MARK: - Raw Coordinate Parsing

    /// Parses raw coordinate pairs like "37.7749, -122.4194" or "37.7749 -122.4194"
    public static func parseCoordinate(from text: String) -> CLLocationCoordinate2D? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split by comma or whitespace
        let separators = CharacterSet(charactersIn: ", \t")
        let components = trimmed
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard components.count == 2,
              let lat = Double(components[0]),
              let lon = Double(components[1]) else {
            return nil
        }

        // Validate bounds
        guard lat >= -90.0 && lat <= 90.0,
              lon >= -180.0 && lon <= 180.0 else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Google Maps & Apple Maps URL Resolver

    /// Extracts coordinate from Google Maps / Apple Maps URLs or expands shortlinks.
    public static func parseMapsURL(from text: String) async -> CLLocationCoordinate2D? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            return nil
        }

        let isMapsHost = host.contains("google.com") ||
                         host.contains("goo.gl") ||
                         host.contains("apple.com")

        guard isMapsHost else { return nil }

        // 1. Try immediate regex extraction on the given URL string
        if let coord = extractCoordinate(fromURLString: trimmed) {
            return coord
        }

        // 2. If it is a shortlink (goo.gl / maps.app.goo.gl), resolve HTTP redirect
        if host.contains("goo.gl") {
            if let expandedString = await resolveRedirect(url: url) {
                if let coord = extractCoordinate(fromURLString: expandedString) {
                    return coord
                }
            }
        }

        return nil
    }

    /// Resolves redirects for short links with 5s timeout
    private static func resolveRedirect(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let finalURL = response.url?.absoluteString {
                return finalURL
            }
        } catch {
            // Fall back to GET if HEAD failed
            var getReq = URLRequest(url: url)
            getReq.timeoutInterval = 5.0
            if let (_, getResp) = try? await URLSession.shared.data(for: getReq),
               let finalURL = getResp.url?.absoluteString {
                return finalURL
            }
        }
        return nil
    }

    /// Extracts coordinates from various Maps URL patterns
    public static func extractCoordinate(fromURLString str: String) -> CLLocationCoordinate2D? {
        // Pattern 1: @lat,lon, e.g. @37.7749,-122.4194
        if let match = matchRegex(pattern: #"@(-?\d+\.?\d*),(-?\d+\.?\d*)"#, in: str) {
            if let lat = Double(match.0), let lon = Double(match.1),
               lat >= -90 && lat <= 90, lon >= -180 && lon <= 180 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }

        // Pattern 2: [?&](?:q|ll|center|saddr|daddr)=(-?\d+\.?\d*),(-?\d+\.?\d*)
        if let match = matchRegex(pattern: #"[?&](?:q|ll|center|saddr|daddr)=(-?\d+\.?\d*),(-?\d+\.?\d*)"#, in: str) {
            if let lat = Double(match.0), let lon = Double(match.1),
               lat >= -90 && lat <= 90, lon >= -180 && lon <= 180 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }

        // Pattern 3: !3dlat!4dlon (Google Maps protobuf params in URL)
        if let match = matchRegex(pattern: #"!3d(-?\d+\.?\d*)!4d(-?\d+\.?\d*)"#, in: str) {
            if let lat = Double(match.0), let lon = Double(match.1),
               lat >= -90 && lat <= 90, lon >= -180 && lon <= 180 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }

        return nil
    }

    private static func matchRegex(pattern: String, in string: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges >= 3,
              let r1 = Range(match.range(at: 1), in: string),
              let r2 = Range(match.range(at: 2), in: string) else {
            return nil
        }
        return (String(string[r1]), String(string[r2]))
    }

    // MARK: - Hybrid Search Engine

    /// Performs search across Direct Coordinates, Maps URLs, Apple MKLocalSearch, and Photon fallback
    public func search(query: String, region: MKCoordinateRegion? = nil) async -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. Direct coordinate check
        if let coord = Self.parseCoordinate(from: trimmed) {
            return [
                PlaceSuggestion(
                    title: "Coordinate Location",
                    subtitle: String(format: "%.5f, %.5f", coord.latitude, coord.longitude),
                    coordinate: coord
                )
            ]
        }

        // 2. Maps URL check
        if trimmed.lowercased().contains("http://") ||
           trimmed.lowercased().contains("https://") ||
           trimmed.lowercased().contains("maps.") ||
           trimmed.lowercased().contains("goo.gl") {
            if let coord = await Self.parseMapsURL(from: trimmed) {
                return [
                    PlaceSuggestion(
                        title: "Shared Maps Pin",
                        subtitle: String(format: "%.5f, %.5f", coord.latitude, coord.longitude),
                        coordinate: coord
                    )
                ]
            }
        }

        // 3. Apple MKLocalSearch
        var results: [PlaceSuggestion] = []
        let localResults = await searchAppleLocal(query: trimmed, region: region)
        results.append(contentsOf: localResults)

        // 4. If fewer than 4 results, augment with Photon Geocoding API
        if results.count < 4 {
            let photonResults = await searchPhoton(query: trimmed)
            for item in photonResults {
                if !results.contains(where: { $0 == item }) {
                    results.append(item)
                }
            }
        }

        return results
    }

    // MARK: - MKLocalSearch Provider

    private func searchAppleLocal(query: String, region: MKCoordinateRegion?) async -> [PlaceSuggestion] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let reg = region {
            request.region = reg
        }

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            return response.mapItems.prefix(8).map { item in
                let title = item.name ?? "Unknown Location"
                let sub = item.placemark.title ?? item.placemark.formattedAddress ?? ""
                return PlaceSuggestion(
                    title: title,
                    subtitle: sub,
                    coordinate: item.placemark.coordinate
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Photon Geocoding Provider (Komoot OpenStreetMap)

    private func searchPhoton(query: String) async -> [PlaceSuggestion] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://photon.komoot.io/api/?q=\(encoded)&limit=6") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = json["features"] as? [[String: Any]] else {
                return []
            }

            var list: [PlaceSuggestion] = []
            for feat in features {
                guard let geometry = feat["geometry"] as? [String: Any],
                      let coords = geometry["coordinates"] as? [Double],
                      coords.count >= 2 else { continue }

                let lon = coords[0]
                let lat = coords[1]
                let props = feat["properties"] as? [String: Any] ?? [:]
                let name = props["name"] as? String ?? "Location"
                let city = props["city"] as? String ?? props["state"] as? String ?? ""
                let country = props["country"] as? String ?? ""
                let subtitle = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")

                list.append(PlaceSuggestion(
                    title: name,
                    subtitle: subtitle.isEmpty ? String(format: "%.4f, %.4f", lat, lon) : subtitle,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                ))
            }
            return list
        } catch {
            return []
        }
    }
}

// MARK: - Placemark Formatted Address Helper

private extension MKPlacemark {
    var formattedAddress: String? {
        let parts = [subThoroughfare, thoroughfare, locality, administrativeArea, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
