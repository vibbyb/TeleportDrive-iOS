//
//  TeleportView.swift
//  StikDebug
//
//  Instant 1-tap teleportation and permanent standstill hold tab for TeleportDrive.
//

import SwiftUI
import MapKit
import CoreLocation

struct TeleportView: View {
    @ObservedObject var vm: SimulateViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var showSaveAlert = false
    @State private var newPinTitle = ""

    private var targetCoord: CLLocationCoordinate2D? {
        vm.startPinCoordinate ?? vm.currentCoordinate ?? vm.userLocation
    }

    private var targetName: String {
        vm.selectedDestinationName ?? vm.startWaypoint?.name ?? "Selected Location"
    }

    var body: some View {
        ZStack {
            // Full screen Google Map
            GoogleMapView(
                mapStyle: vm.googleMapStyle,
                startCoordinate: vm.startPinCoordinate ?? vm.userLocation,
                endCoordinate: nil,
                currentCoordinate: vm.currentCoordinate,
                isHolding: vm.isHoldingLocation,
                routePolyline: nil,
                cameraTarget: $vm.cameraTarget,
                onMapTap: { coord in
                    handleMapSelection(coord)
                },
                onLongPress: { coord in
                    handleMapSelection(coord)
                }
            )
            .ignoresSafeArea()
            .onTapGesture {
                isSearchFocused = false
            }

            // Top Floating Search & Quick Pins Card
            VStack(spacing: 8) {
                topFloatingSearchCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                bottomFloatingActionCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            vm.selectedMode = .standstill
            vm.requestUserLocationAccess()
        }
        .alert("Save Quick Pin", isPresented: $showSaveAlert) {
            TextField("Pin Name", text: $newPinTitle)
            Button("Save") {
                if let coord = targetCoord {
                    let title = newPinTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? targetName : newPinTitle
                    vm.saveCurrentQuickPin(title: title, coordinate: coord)
                    newPinTitle = ""
                }
            }
            Button("Cancel", role: .cancel) {
                newPinTitle = ""
            }
        }
    }

    // MARK: - Top Floating Search & Quick Pins

    private var topFloatingSearchCard: some View {
        VStack(spacing: 10) {
            // Search Input Row
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search address, place, or lat,lon...", text: $vm.searchQuery)
                    .font(.subheadline)
                    .focused($isSearchFocused)
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

            // Autocomplete Dropdown
            if !vm.searchSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.searchSuggestions.prefix(4)) { suggestion in
                        Button {
                            vm.selectSearchSuggestion(suggestion, action: .teleportImmediately)
                            isSearchFocused = false
                        } label: {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.orange)
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

            // Quick Saved Pins + Presets + Save Pin Button
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        if targetCoord != nil {
                            newPinTitle = targetName
                            showSaveAlert = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption2)
                            Text("Save Pin")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                    }

                    ForEach(vm.savedQuickPins + PlaceSuggestion.presets) { pin in
                        Button {
                            vm.selectSearchSuggestion(pin, action: .teleportImmediately)
                            isSearchFocused = false
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

    // MARK: - Bottom Floating Action Card

    private var bottomFloatingActionCard: some View {
        VStack(spacing: 12) {
            // Live Status Banner
            HStack {
                if vm.isHoldingLocation {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("🟢 Holding Location Forever (1 Hz Heartbeat Active)")
                            .font(.caption.bold())
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
                        Text("⚪ Real GPS Active (0% Background Battery)")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }
                Spacer()
            }

            // Target Pin Summary
            if let coord = targetCoord {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(targetName)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // Two Crystal-Clear Buttons
            VStack(spacing: 8) {
                // Button 1: Teleport Here
                Button {
                    if let coord = targetCoord {
                        vm.instantTeleport(to: coord, name: targetName)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.body.bold())
                        Text("Teleport Here")
                            .font(.headline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(targetCoord != nil ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(targetCoord == nil)

                // Button 2: Stop Spoofing (Restore Real GPS)
                if vm.isHoldingLocation || vm.isPlaying {
                    Button(role: .destructive) {
                        vm.restoreRealGPS()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "location.slash.fill")
                            Text("Stop Spoofing (Restore Real GPS)")
                                .font(.subheadline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
    }

    // MARK: - Map Tap Selection

    private func handleMapSelection(_ coord: CLLocationCoordinate2D) {
        let title = String(format: "%.5f, %.5f", coord.latitude, coord.longitude)
        vm.selectTeleportTarget(coordinate: coord, title: title)
    }
}
