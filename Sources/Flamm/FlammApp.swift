import SwiftUI

@main
struct FlammApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Label("Flamm", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
