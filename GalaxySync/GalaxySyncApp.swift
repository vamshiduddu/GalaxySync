import SwiftUI

@main
struct GalaxySyncApp: App {
    @StateObject private var syncEngine = SyncEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncEngine)
        }
    }
}
