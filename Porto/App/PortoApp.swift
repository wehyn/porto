import AppKit
import SwiftUI

@main
struct PortoApp: App {
    var body: some Scene {
        MenuBarExtra("Porto", systemImage: "network") {
            Text("Porto")
        }
        .menuBarExtraStyle(.window)
    }
}
