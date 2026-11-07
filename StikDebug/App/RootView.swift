import SwiftUI

struct RootView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @StateObject private var simulateVM = SimulateViewModel()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if hasCompletedOnboarding || PairingFileStore.hasPairingFile {
                mainTabs
            } else {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .onAppear {
            if PairingFileStore.hasPairingFile {
                hasCompletedOnboarding = true
            }
        }
    }

    private var mainTabs: some View {
        TabView {
            NavigationStack {
                DriveView(vm: simulateVM)
            }
            .tabItem {
                Label("Drive", systemImage: "car.fill")
            }

            NavigationStack {
                TeleportView(vm: simulateVM)
            }
            .tabItem {
                Label("Teleport", systemImage: "location.fill")
            }

            NavigationStack {
                RouteSimSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}
