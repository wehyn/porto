import AppKit
import SwiftUI

@main
struct PortoApp: App {
    @StateObject private var monitor: PortMonitor
    @StateObject private var presentationObserver: MenuPresentationObserver

    init() {
        let runner = LsofRunner()
        let inspector = DarwinProcessInspector()
        let scanner = PortScanner(runner: runner, inspector: inspector)
        let terminator = ProcessTerminator(
            validator: scanner,
            inspector: inspector,
            signalSender: DarwinProcessSignalSender()
        )
        _monitor = StateObject(wrappedValue: PortMonitor(
            localScanner: scanner,
            terminator: terminator,
            hostCatalog: SSHHostCatalog(),
            remoteScannerFactory: { host in RemotePortScanner(host: host) }
        ))
        _presentationObserver = StateObject(wrappedValue: MenuPresentationObserver())
    }

    var body: some Scene {
        MenuBarExtra("Porto", systemImage: "network") {
            PortPopoverView(monitor: monitor, presentationObserver: presentationObserver)
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
        .menuBarExtraStyle(.window)
    }
}
