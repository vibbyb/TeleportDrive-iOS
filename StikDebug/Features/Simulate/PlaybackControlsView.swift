import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var vm: SimulateViewModel

    var body: some View {
        VStack(spacing: 12) {
            // 1. Status Indicator Header
            statusHeaderRow

            // 2. 1-Tap Action Row when Pin / Destination is ready and not playing
            if vm.placementPhase == .ready && !vm.isPlaying && !vm.isAutoParking {
                oneTapActionRow
            }

            // 3. Auto-Park Banner
            if vm.isAutoParking {
                autoParkBanner
            }

            // 4. Progress Scrubber Row
            if showProgressRow {
                progressRow
            }

            // 5. Standard Transport Controls
            transportRow

            // 6. Cruise Speed & Auto-Park 9m Toggle
            if vm.selectedMode == .drive || vm.selectedMode == .custom {
                driveSpeedAndOptionsRow
            }

            // 7. Speed multiplier options (0.5x .. 10x)
            if vm.selectedMode != .standstill {
                speedMultiplierRow
            }
        }
        .padding(12)
    }

    // MARK: - Status Header

    private var statusHeaderRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Text(statusText)
                .font(.subheadline.bold())
                .foregroundStyle(statusColor)

            Spacer()

            if vm.isHoldingLocation || vm.isPlaying || vm.isAutoParking {
                Button("Restore Real GPS") {
                    vm.restoreRealGPS()
                }
                .font(.caption2.bold())
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        if vm.isAutoParking { return .orange }
        if vm.isPlaying { return .blue }
        if vm.isHoldingLocation || vm.selectedMode == .standstill { return .green }
        return .secondary
    }

    private var statusText: String {
        if vm.isAutoParking {
            let m = vm.autoParkRemainingSeconds / 60
            let s = vm.autoParkRemainingSeconds % 60
            return "🅿️ Auto-Park Hold (\(String(format: "%d:%02d", m, s)))"
        }
        if vm.isPlaying {
            let mph = Int(vm.stats.speedMps * 2.23694)
            return "🚗 Driving (\(mph) mph)"
        }
        if vm.isHoldingLocation || vm.selectedMode == .standstill {
            return "🟢 Holding GPS (Locked)"
        }
        return "⚪ Real GPS"
    }

    // MARK: - 1-Tap Action Row

    private var oneTapActionRow: some View {
        HStack(spacing: 10) {
            Button {
                if let target = vm.endPinCoordinate ?? vm.startPinCoordinate {
                    let name = vm.selectedDestinationName ?? "Teleport Pin"
                    vm.instantTeleport(to: target, name: name)
                }
            } label: {
                Label("Teleport & Hold", systemImage: "bolt.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button {
                vm.playPause()
            } label: {
                Label("Start Drive", systemImage: "car.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Auto-Park Banner

    private var autoParkBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "parkingsign.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                let m = vm.autoParkRemainingSeconds / 60
                let s = vm.autoParkRemainingSeconds % 60
                Text("Auto-Park Hold: \(String(format: "%d:%02d", m, s))")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text("Spoofed at destination for Life360 & Find My")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                vm.player.stopAutoPark()
            }
            .font(.caption2.bold())
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Cruise Speed & Options

    private var driveSpeedAndOptionsRow: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Cruise: \(Int(vm.driveSpeedMph)) mph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: $vm.driveSpeedMph, in: 5...120, step: 1)
            }

            Toggle("Auto-Park 9m (Life360)", isOn: $vm.autoParkEnabled)
                .font(.caption)
                .foregroundStyle(.primary)
                .tint(.orange)
        }
        .padding(.horizontal, 4)
    }

    private var showProgressRow: Bool {
        vm.selectedMode != .standstill && vm.waypoints.count >= 2 && vm.stats.totalDistance > 0
    }

    // MARK: - Progress

    private var progressRow: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { vm.stats.progress },
                    set: { vm.scrub(to: $0) }
                ),
                in: 0...1
            )
            .tint(.accentColor)

            HStack {
                Text(formatTime(vm.stats.elapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(etaLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 24) {
            Button {
                vm.stop()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .disabled(vm.stats.odometer == 0 && !vm.isPlaying)

            Button {
                vm.playPause()
            } label: {
                ZStack {
                    if vm.isPreparing {
                        ProgressView()
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 48, height: 48)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .disabled(vm.isPreparing)

            if vm.selectedMode != .standstill {
                Button {
                    vm.loopEnabled.toggle()
                } label: {
                    Image(systemName: vm.loopEnabled ? "repeat.1" : "repeat")
                        .font(.title3)
                        .foregroundStyle(vm.loopEnabled ? Color.accentColor : .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Speed multiplier

    private var speedMultiplierRow: some View {
        HStack {
            Text("Speed")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Speed", selection: $vm.speedMultiplier) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("5×").tag(5.0)
                Text("10×").tag(10.0)
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.speedMultiplier) { _, new in
                vm.player.speedMultiplier = new
            }

            if vm.speedMultiplier > 2 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("High multipliers inflate derived speed — use for preview only")
            }
        }
    }

    // MARK: - Helpers

    private var etaLabel: String {
        if vm.isPlaying, vm.stats.eta > 0 {
            return "ETA \(formatTime(vm.stats.eta))"
        }
        return formatDistance(vm.stats.totalDistance)
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let t = Int(s)
        if t < 3600 { return String(format: "%d:%02d", t / 60, t % 60) }
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private func formatDistance(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return String(format: "%.0f m", m)
    }
}
