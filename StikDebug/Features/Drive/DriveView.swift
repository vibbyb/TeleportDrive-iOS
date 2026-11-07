//
//  DriveView.swift
//  StikDebug
//
//  Clean, modern turn-by-turn driving simulation tab for TeleportDrive.
//

import SwiftUI
import MapKit
import CoreLocation

struct DriveView: View {
    @ObservedObject var vm: SimulateViewModel
    @FocusState private var isDestinationFocused: Bool
    @FocusState private var isStartFocused: Bool

    var body: some View {
        ZStack {
            // Full screen Google Map
            GoogleMapView(
                mapStyle: vm.googleMapStyle,
                startCoordinate: vm.startPinCoordinate ?? vm.userLocation,
                endCoordinate: vm.endPinCoordinate,
                currentCoordinate: vm.currentCoordinate,
                isHolding: vm.isHoldingLocation,
                routePolyline: vm.routePolyline,
                cameraTarget: $vm.cameraTarget,
                onMapTap: { coord in
                    handleMapTap(coord)
                },
                onLongPress: { coord in
                    handleMapTap(coord)
                }
            )
            .ignoresSafeArea()
            .onTapGesture {
                isDestinationFocused = false
                isStartFocused = false
            }

            // Overlay cards
            VStack(spacing: 8) {
                topFloatingRouteCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                bottomFloatingDriveCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            vm.selectedMode = .drive
            if vm.useCurrentLocationForStart && vm.startWaypoint == nil {
                vm.selectCurrentLocationAsStart()
            }
            vm.requestUserLocationAccess()
        }
    }

    // MARK: - Top Floating Route Card

    private var topFloatingRouteCard: some View {
        VStack(spacing: 10) {
            // Start Row
            HStack(spacing: 8) {
                Image(systemName: "location.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 18))

                Text("From:")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                if vm.useCurrentLocationForStart {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(vm.selectedStartName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .clipShape(Capsule())

                    Spacer()

                    Button("Change") {
                        vm.useCurrentLocationForStart = false
                        vm.startSearchQuery = ""
                        isStartFocused = true
                    }
                    .font(.caption.bold())
                } else {
                    TextField("Start address or tap map...", text: $vm.startSearchQuery)
                        .font(.subheadline)
                        .focused($isStartFocused)
                        .textFieldStyle(.plain)

                    if !vm.startSearchQuery.isEmpty {
                        Button {
                            vm.startSearchQuery = ""
                            vm.startSuggestions = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }

                    Button("GPS") {
                        vm.selectCurrentLocationAsStart()
                        isStartFocused = false
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                }
            }

            // Start Suggestions Dropdown
            if !vm.startSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.startSuggestions.prefix(4)) { suggestion in
                        Button {
                            vm.selectStartSuggestion(suggestion)
                            isStartFocused = false
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }
                        Divider()
                    }
                }
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // Destination Row
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.red)
                    .font(.system(size: 18))

                Text("To:")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                TextField("Search destination address or lat,lon...", text: $vm.searchQuery)
                    .font(.subheadline)
                    .focused($isDestinationFocused)
                    .textFieldStyle(.plain)

                if !vm.searchQuery.isEmpty {
                    Button {
                        vm.searchQuery = ""
                        vm.searchSuggestions = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Destination Suggestions Dropdown
            if !vm.searchSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.searchSuggestions.prefix(4)) { suggestion in
                        Button {
                            vm.selectSearchSuggestion(suggestion, action: .setAsDestination)
                            isDestinationFocused = false
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                        }
                        Divider()
                    }
                }
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Quick Saved Pins & Presets Scroll Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.savedQuickPins + PlaceSuggestion.presets) { pin in
                        Button {
                            vm.selectSearchSuggestion(pin, action: .setAsDestination)
                            isDestinationFocused = false
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: pin.isPreset ? "star.fill" : "bookmark.fill")
                                    .font(.caption2)
                                    .foregroundColor(pin.isPreset ? .orange : .blue)
                                Text(pin.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(UIColor.secondarySystemBackground))
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            // Map Style Segmented Picker
            Picker("Map Style", selection: $vm.googleMapStyle) {
                Text("Street").tag(GoogleMapStyle.street)
                Text("Satellite").tag(GoogleMapStyle.satellite)
                Text("Hybrid").tag(GoogleMapStyle.hybrid)
            }
            .pickerStyle(.segmented)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
    }

    // MARK: - Bottom Floating Drive Control Card

    private var bottomFloatingDriveCard: some View {
        VStack(spacing: 12) {
            // Status Header
            HStack {
                if vm.isPlaying {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                        Text("🚗 Driving • \(Int(vm.stats.speedMph)) mph")
                            .font(.subheadline.bold())
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
                } else if vm.isHoldingLocation {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("🟢 Parked & Holding at Destination")
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 8, height: 8)
                        Text("⚪ Ready — Idle (0% Battery)")
                            .font(.subheadline.bold())
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }

                Spacer()

                if vm.isPlaying || vm.isHoldingLocation {
                    Button(role: .destructive) {
                        vm.restoreRealGPS()
                    } label: {
                        Label("Stop Spoofing", systemImage: "location.slash.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            // Speed Selector Row
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Speed:")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    TextField("MPH", text: $vm.customSpeedText)
                        .keyboardType(.numberPad)
                        .frame(width: 48)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .font(.caption.bold())

                    Text("mph")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Set") {
                        vm.applyCustomSpeedText(vm.customSpeedText)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.bold())

                    Spacer()

                    // Preset chips
                    ForEach(SimulateViewModel.driveSpeedPresetsMph, id: \.self) { preset in
                        let isSelected = abs(vm.driveSpeedMph - preset) < 0.5
                        Button {
                            vm.applySpeedPreset(preset)
                        } label: {
                            Text("\(Int(preset)) mph")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.blue : Color(UIColor.tertiarySystemFill))
                                .foregroundColor(isSelected ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }

                Text("Smart curve & turn slowdown active • Life360 1 Hz telemetry")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Live Stats Row
            if vm.stats.totalDistance > 0 || vm.placementPhase == .ready {
                VStack(spacing: 6) {
                    ProgressView(value: vm.stats.progress)
                        .tint(.blue)

                    let miles = vm.stats.totalDistance * 0.000621371
                    let km = vm.stats.totalDistance / 1000.0
                    let etaSec = max(0, Int(vm.stats.eta))
                    let etaMin = etaSec / 60
                    let etaRemSec = etaSec % 60

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Distance").font(.caption2).foregroundColor(.secondary)
                            Text(String(format: "%.1f mi (%.1f km)", miles, km))
                                .font(.caption.bold())
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text("Speed").font(.caption2).foregroundColor(.secondary)
                            Text("\(Int(vm.stats.speedMph)) mph")
                                .font(.caption.bold())
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("ETA").font(.caption2).foregroundColor(.secondary)
                            Text(String(format: "%d:%02d", etaMin, etaRemSec))
                                .font(.caption.bold())
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            // Primary Action Button
            Button {
                vm.playPause()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "car.fill")
                        .font(.body.bold())
                    Text(vm.isPlaying ? "Pause / Stop Drive" : "Start Drive")
                        .font(.headline.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(vm.isPlaying ? Color.orange : (vm.canPlay ? Color.blue : Color.gray))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!vm.canPlay && !vm.isPlaying)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
    }

    // MARK: - Map Tap Helper

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        if vm.useCurrentLocationForStart && vm.startWaypoint == nil {
            vm.selectCurrentLocationAsStart()
        }

        let title = String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
        let end = Waypoint(coordinate: coord, name: title)
        let start = vm.startWaypoint ?? Waypoint(coordinate: vm.currentCoordinate ?? vm.userLocation ?? coord, name: "Start")
        vm.startWaypoint = start
        vm.endWaypoint = end
        vm.waypoints = [start, end]
        vm.selectedMode = .drive
        vm.placementPhase = .ready
        Task { await vm.refreshRoutedPolyline() }
    }
}
