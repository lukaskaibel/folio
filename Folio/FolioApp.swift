import FolioKit
import SwiftUI

@main
struct FolioApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FolioAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        FolioScene()
    }
}
