import AppKit
import SwiftUI

@main
struct PortoApp: App {
    @StateObject private var monitor: PortMonitor
    @StateObject private var presentationObserver: MenuPresentationObserver

    init() {
        let runner = LsofRunner()
        let sshRunner = SSHCommandRunner()
        let inspector = DarwinProcessInspector()
        let scanner = PortScanner(runner: runner, inspector: inspector)
        let terminator = ProcessTerminator(
            validator: scanner,
            inspector: inspector,
            signalSender: DarwinProcessSignalSender()
        )
        let profileStore = UserDefaultsRemoteServerProfileStore()
        _monitor = StateObject(wrappedValue: PortMonitor(
            localScanner: scanner,
            terminator: terminator,
            remoteScannerFactory: { profile in RemotePortScanner(profile: profile, runner: sshRunner) },
            profileStore: profileStore,
            remoteTerminatorFactory: { profile in
                RemoteProcessTerminator(profile: profile, runner: sshRunner)
            }
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

        Window("Settings", id: "settings") {
            RemoteServerSettingsView(monitor: monitor)
        }
    }
}
