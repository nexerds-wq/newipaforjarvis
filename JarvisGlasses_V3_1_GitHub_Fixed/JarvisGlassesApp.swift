import SwiftUI

@main
struct JarvisGlassesApp: App {
    @StateObject private var coordinator = JarvisCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator.bluetooth)
                .environmentObject(coordinator.wakeWord)
                .onAppear {
                    coordinator.resumeServices()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Do NOT stop the listener in background. UIBackgroundModes=audio keeps
                    // the active microphone pipeline alive while the phone is locked/backgrounded.
                    if newPhase == .active {
                        coordinator.resumeServices()
                    }
                }
        }
    }
}
