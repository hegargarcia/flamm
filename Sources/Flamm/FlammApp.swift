import SwiftUI

@main
struct FlammApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model, updater: updater)
        } label: {
            Label("Flamm", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
