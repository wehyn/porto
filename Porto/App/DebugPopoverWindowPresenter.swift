#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class DebugPopoverWindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var pendingMonitor: PortMonitor?
    private var pendingUpdater: PortoUpdater?
    private var launchObserver: NSObjectProtocol?

    func schedulePresentation(monitor: PortMonitor, updater: PortoUpdater) {
        pendingMonitor = monitor
        pendingUpdater = updater

        if NSApplication.shared.isRunning {
            DispatchQueue.main.async { [weak self] in
                self?.presentPendingWindow()
            }
            return
        }

        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.presentPendingWindow()
            }
        }
    }

    func present(monitor: PortMonitor, updater: PortoUpdater) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        if let window {
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: DebugPopoverWindowContent(monitor: monitor, updater: updater)
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PortPopoverView.popoverWidth,
                height: 560
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Porto Debug Popover"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(
            NSSize(width: PortPopoverView.popoverWidth, height: 560)
        )
        window.center()
        self.window = window

        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentPendingWindow() {
        guard let pendingMonitor, let pendingUpdater else { return }
        self.pendingMonitor = nil
        self.pendingUpdater = nil
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        present(monitor: pendingMonitor, updater: pendingUpdater)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

@MainActor
private struct DebugPopoverWindowContent: View {
    @ObservedObject private var monitor: PortMonitor
    @ObservedObject private var updater: PortoUpdater
    @StateObject private var presentationObserver: MenuPresentationObserver

    init(monitor: PortMonitor, updater: PortoUpdater) {
        self.monitor = monitor
        self.updater = updater
        _presentationObserver = StateObject(wrappedValue: MenuPresentationObserver())
    }

    var body: some View {
        PortPopoverView(
            monitor: monitor,
            presentationObserver: presentationObserver,
            updater: updater
        )
        .background(
            MenuWindowProbe { window in
                presentationObserver.attach(to: window)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            presentationObserver.contentDidAppear()
            monitor.setPresented(presentationObserver.isPresented)
        }
        .onDisappear {
            presentationObserver.provisionalContentDidDisappear()
        }
        .onChange(of: presentationObserver.isPresented) { _, presented in
            monitor.setPresented(presented)
        }
    }
}
#endif
