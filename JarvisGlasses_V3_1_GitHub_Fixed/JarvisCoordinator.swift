import Foundation

@MainActor
final class JarvisCoordinator: ObservableObject {
    static let shared = JarvisCoordinator()

    let bluetooth = BLEController.shared
    let wakeWord = WakeWordManager.shared

    private init() {
        wakeWord.onWake = { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.bluetooth.wakeSavedGlasses()
                    await MainActor.run {
                        self.bluetooth.status = "Hey Jarvis → M02S wake sent ✓"
                    }
                } catch {
                    await MainActor.run {
                        self.bluetooth.status = "Hey Jarvis heard, but wake failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func resumeServices() {
        bluetooth.reconnectSavedGlasses()
        wakeWord.resumeIfNeeded()
    }
}
