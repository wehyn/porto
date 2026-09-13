import AppKit

@MainActor
enum SettingsWindowPresenter {
    private static let maxAttempts = 4

    static func bringToFront(attemptsRemaining: Int = maxAttempts) {
        guard let window = NSApp.windows.first(where: { $0.title == "Settings" }) else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async {
                bringToFront(attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
