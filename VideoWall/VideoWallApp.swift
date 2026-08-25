import SwiftUI

// MARK: - Entry Point

@main
struct VideoWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We manage all windows manually via AppDelegate.
        // A dummy Settings scene satisfies the App protocol.
        Settings {
            EmptyView()
        }
    }
}
