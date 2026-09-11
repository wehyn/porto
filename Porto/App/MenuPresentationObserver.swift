import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuPresentationObserver: ObservableObject {
    @Published private(set) var isPresented = false

    private weak var observedWindow: NSWindow?
    private var notificationTokens: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        guard observedWindow !== window else {
            updateFromWindow()
            return
        }
        removeObservers()
        observedWindow = window
        guard let window else {
            setPresented(false)
            return
        }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        notificationTokens = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch name {
                    case NSWindow.willCloseNotification,
                         NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification:
                        self.setPresented(false)
                    default:
                        self.updateFromWindow()
                    }
                }
            }
        }
        notificationTokens.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setPresented(false)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateFromWindow()
                }
            }
        )
        updateFromWindow()
    }

    func contentDidAppear() {
        updateFromWindow()
    }

    func provisionalContentDidDisappear() {
        guard let window = observedWindow else {
            setPresented(false)
            return
        }
        if !window.isVisible || !window.isKeyWindow || !NSApp.isActive {
            setPresented(false)
        }
    }

    static func isPresented(
        windowIsVisible: Bool,
        windowIsKey: Bool,
        windowIsMiniaturized: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        windowIsVisible && windowIsKey && applicationIsActive && !windowIsMiniaturized
    }

    private func updateFromWindow() {
        guard let window = observedWindow else {
            setPresented(false)
            return
        }
        let visible = Self.isPresented(
            windowIsVisible: window.isVisible,
            windowIsKey: window.isKeyWindow,
            windowIsMiniaturized: window.isMiniaturized,
            applicationIsActive: NSApp.isActive
        )
        setPresented(visible)
    }

    private func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

}

struct MenuWindowProbe: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindowChange = onWindowChange
        if nsView.window != nil {
            onWindowChange(nsView.window)
        }
    }

    final class ProbeView: NSView {
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
