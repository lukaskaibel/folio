import NotebookKit
import SwiftUI

@main
struct NotebookApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NotebookAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        NotebookScene()
    }
}
