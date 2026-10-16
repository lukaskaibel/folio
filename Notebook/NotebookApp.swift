import NotebookKit
import SwiftUI

@main
struct NotebookApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NotebookAppDelegate.self) private var appDelegate
    #endif

    init() {
        NotebookSettings.importFolioSettings()
    }

    var body: some Scene {
        NotebookScene()
    }
}
