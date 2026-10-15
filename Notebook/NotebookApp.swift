import NotebookKit
import SwiftUI

@main
struct NotebookApp: App {
    @NSApplicationDelegateAdaptor(NotebookAppDelegate.self) private var appDelegate

    init() {
        NotebookSettings.importFolioSettings()
    }

    var body: some Scene {
        NotebookScene()
    }
}
