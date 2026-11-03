import SwiftUI
import MapKit

struct RouteEditorView: View {
    @StateObject private var vm = SimulateViewModel()
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var showSavePinSheet = false
    @State private var newPinTitle = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // MARK: - Google Maps Full-Screen Layer
            mapLayer

            // MARK: - Top Floating UI (Search, Presets, Style)
            VStack(spacing: 8) {
                topSearchBarRow

                presetsScrollView

                if !vm.searchSuggestions.isEmpty && !vm.searchQuery.isEmpty {
                    searchSuggestionsDropdown
                }

                if let prompt = vm.placementPrompt {
                    Text(prompt)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // MARK: - Bottom Floating Controls Sheet
            VStack {
                Spacer()
                controlsOverlay
            }
        }
        .navigationTitle("RouteSim")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .onAppear {
            vm.startUserLocationUpdates()
            if vm.placementPhase == .idle {
                vm.beginNewRoute(for: vm.selectedMode)
            }
        }
        .onDisappear {
            vm.stopUserLocationUpdates()
        }
        .fileImporter(
            isPresented: $vm.showFilePicker,
            allowedContentTypes: GPXImporter.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.handleImport(url: url)
            }
        }
        .alert("Import Error", isPresented: .constant(vm.importError != nil)) {
            Button("OK") { vm.importError = nil }
        } message: {
            Text(vm.importError ?? "")
        }
        .sheet(isPresented: $vm.showSaveSheet) {
            SaveRouteSheet(name: $vm.routeName) {
                vm.saveToLibrary()
            }
        }
        .sheet(isPresented: $showSavePinSheet) {
            SavePinSheet(
                title: $newPinTitle,
                coordinate: vm.endPinCoordinate ?? vm.startPinCoordinate ?? vm.userLocation
            ) {
                if let coord = vm.endPinCoordinate ?? vm.startPinCoordinate ?? vm.userLocation {
                    vm.saveCurrentQuickPin(title: newPinTitle, coordinate: coord)
                    newPinTitle = ""
                }
            }
        }
    }

    // MARK: - Map Layer

    private var mapLayer: some View {
        GoogleMapView(
            mapStyle: vm.googleMapStyle,
            startCoordinate: vm.startPinCoordinate,
            endCoordinate: vm.endPinCoordinate,
            currentCoordinate: vm.currentCoordinate,
            isHolding: vm.isHoldingLocation || vm.selectedMode == .standstill,
            routePolyline: vm.routePolyline,
            cameraTarget: $vm.cameraTarget,
            onMapTap: { coordinate in
                isSearchFocused = false
                vm.handleMapTap(at: coordinate)
            }
        )
        .ignoresSafeArea(edges: .all)
    }

    // MARK: - Search Bar & Style Selector

    private var topSearchBarRow: some View {
        HStack(spacing: 8) {
            // Search Input Field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Search Google Maps, link, or lat,lon...", text: $vm.searchQuery)
                    .focused($isSearchFocused)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        vm.performSearch()
                    }

                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if !vm.searchQuery.isEmpty {
                    Button {
                        vm.searchQuery = ""
                        vm.searchSuggestions = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

            // Map Style Segmented Picker
            Picker("Style", selection: $vm.googleMapStyle) {
                ForEach(GoogleMapStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }

    // MARK: - Presets Scroll View

    private var presetsScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Save Pin Button
                Button {
                    showSavePinSheet = true
                } label: {
                    Label("Save Pin", systemImage: "plus.circle.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial)
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // User-saved pins first
                ForEach(vm.savedQuickPins) { pin in
                    presetMenu(for: pin, isCustom: true)
                }

                // Built-in presets
                ForEach(PlaceSuggestion.presets) { preset in
                    presetMenu(for: preset, isCustom: false)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func presetMenu(for place: PlaceSuggestion, isCustom: Bool) -> some View {
        Menu {
            Button {
                vm.selectSearchSuggestion(place, action: .teleportImmediately)
            } label: {
                Label("Teleport & Hold (Instant)", systemImage: "bolt.fill")
            }

            Button {
                vm.selectSearchSuggestion(place, action: .setAsDestination)
            } label: {
                Label("Drive to Pin", systemImage: "car.fill")
            }

            Button {
                vm.selectSearchSuggestion(place, action: .setAsStart)
            } label: {
                Label("Set as Start", systemImage: "flag.fill")
            }

            if isCustom {
                Divider()
                Button(role: .destructive) {
                    vm.deleteSavedQuickPin(id: place.id)
                } label: {
                    Label("Delete Quick Pin", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCustom ? "star.fill" : "mappin.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(isCustom ? .yellow : .accentColor)
                Text(place.title)
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        }
    }

    // MARK: - Search Suggestions Dropdown

    private var searchSuggestionsDropdown: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.searchSuggestions) { suggestion in
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.isPreset ? "star.circle.fill" : "mappin.and.ellipse")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            // Action buttons
                            HStack(spacing: 6) {
                                Button {
                                    isSearchFocused = false
                                    vm.selectSearchSuggestion(suggestion, action: .teleportImmediately)
                                } label: {
                                    Label("Teleport", systemImage: "bolt.fill")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.orange.opacity(0.18))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    isSearchFocused = false
                                    vm.selectSearchSuggestion(suggestion, action: .setAsDestination)
                                } label: {
                                    Label("Drive", systemImage: "car.fill")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.18))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    // MARK: - Controls overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            modeBar
                .background(.regularMaterial)

            if vm.isPlaying || vm.stats.odometer > 0 {
                LiveStatsView(stats: vm.stats)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            PlaybackControlsView(vm: vm)
                .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut, value: vm.isPlaying)
    }

    private var modeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MovementMode.allCases) { mode in
                    ModeChip(mode: mode, isSelected: vm.selectedMode == mode) {
                        vm.selectMode(mode)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                vm.showFilePicker = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                vm.requestUserLocationAccess()
                vm.useCurrentLocationAsStart()
            } label: {
                Image(systemName: "location.fill")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button("Save Route") { vm.showSaveSheet = true }
                Button("Restore Real GPS", role: .destructive) {
                    vm.restoreRealGPS()
                }
                Button("Clear Route", role: .destructive) {
                    vm.beginNewRoute(for: vm.selectedMode)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Mode chip

private struct ModeChip: View {
    let mode: MovementMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(mode.displayName, systemImage: mode.systemImage)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Save route sheet

struct SaveRouteSheet: View {
    @Binding var name: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Route Name") {
                    TextField("Name", text: $name)
                }
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Save quick pin sheet

struct SavePinSheet: View {
    @Binding var title: String
    var coordinate: CLLocationCoordinate2D?
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Pin Name") {
                    TextField("e.g. Home, Office, Gym", text: $title)
                }
                if let coord = coordinate {
                    Section("Coordinate") {
                        Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Save Quick Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(); dismiss() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || coordinate == nil)
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }
}

// MARK: - SimulateView entry point (referenced from RootView)

struct SimulateView: View {
    var body: some View {
        RouteEditorView()
    }
}
