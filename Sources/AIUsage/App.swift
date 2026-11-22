import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(store)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
