import SwiftUI

@main
struct MainApp: App {
    @State private var sync = try! SyncManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(sync: sync)
        }
        .onChange(of: scenePhase) { _, phase in
            // Suspension kills the QUIC sockets and a stopped Node can't be
            // restarted, so a node's lifetime is one foreground stint. Disk
            // state (identity, roster, statuses) carries across stints.
            switch phase {
            case .active: Task { try? await sync.start() }
            case .background: Task { await sync.stop() }
            default: break
            }
        }
    }
}
