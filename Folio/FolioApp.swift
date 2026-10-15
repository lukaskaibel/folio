import FolioKit
import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(FolioAppDelegate.self) private var appDelegate

    var body: some Scene {
        FolioScene()
    }
}
