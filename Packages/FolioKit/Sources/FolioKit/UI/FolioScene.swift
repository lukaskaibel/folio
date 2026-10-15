import AppKit
import SwiftUI

/// The app's window, its settings and its menus. The app target only has to show this scene.
public struct FolioScene: Scene {
    @State private var workspace = Workspace.shared

    public init() {}

    public var body: some Scene {
        Window("Folio", id: "main") {
            RootView()
                .onAppear {
                    workspace.start()
                    AppIconStore.shared.start()
                    #if DEBUG
                    DebugRemote.startIfRequested(workspace: workspace)
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in workspace.saveAll() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in workspace.saveAll() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { workspace.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(workspace.locations.isEmpty)
                Button("New Folder") { workspace.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workspace.locations.isEmpty)
                Divider()
                Button("Add Location…") { workspace.chooseLocation(iCloud: false) }
            }
            CommandGroup(after: .sidebar) {
                Button(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation(Theme.spring) { workspace.isSidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Go") {
                Button("Search…") {
                    workspace.paletteMode = .search
                    workspace.isPaletteOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Back") { workspace.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!workspace.canGoBack)
                Button("Forward") { workspace.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!workspace.canGoForward)
                Divider()
                Button("Move Note to…") {
                    if let url = workspace.currentURL {
                        workspace.paletteMode = .move(url)
                        workspace.isPaletteOpen = true
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(workspace.currentURL == nil)
            }
            CommandMenu("Format") {
                formatButton("Bold", #selector(MarkdownTextView.toggleBoldface(_:)), "b", .command)
                formatButton("Italic", #selector(MarkdownTextView.toggleItalics(_:)), "i", .command)
                formatButton("Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
                formatButton("Code", #selector(MarkdownTextView.toggleInlineCode(_:)), "e", .command)
                formatButton("Link", #selector(MarkdownTextView.addLink(_:)), "l", .command)
                Divider()
                formatButton("Title", #selector(MarkdownTextView.makeTitle(_:)), "t", [.command, .shift])
                formatButton("Heading", #selector(MarkdownTextView.makeHeading(_:)), "h", [.command, .shift])
                formatButton("Subheading", #selector(MarkdownTextView.makeSubheading(_:)), "j", [.command, .shift])
                formatButton("Body", #selector(MarkdownTextView.makeBody(_:)), "b", [.command, .shift])
                Divider()
                formatButton("Checklist", #selector(MarkdownTextView.makeChecklist(_:)), "l", [.command, .shift])
                formatButton("Mark as Checked", #selector(MarkdownTextView.markChecked(_:)), "u", [.command, .shift])
                formatButton("Bulleted List", #selector(MarkdownTextView.makeBulletedList(_:)), "7", [.command, .shift])
                formatButton("Numbered List", #selector(MarkdownTextView.makeNumberedList(_:)), "9", [.command, .shift])
                formatButton("Block Quote", #selector(MarkdownTextView.makeQuote(_:)), "'", .command)
                Divider()
                formatButton("Increase Indent", #selector(MarkdownTextView.indentLines(_:)), "]", [.command, .option])
                formatButton("Decrease Indent", #selector(MarkdownTextView.outdentLines(_:)), "[", [.command, .option])
            }
        }

        Settings {
            SettingsView(workspace: workspace)
        }
    }

    private func formatButton(_ title: String, _ action: Selector, _ key: Character, _ modifiers: EventModifiers) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }
}

/// Settings, in the system's tabbed window.
struct SettingsView: View {
    let workspace: Workspace
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(workspace: workspace) }
            Tab("App Icon", systemImage: "book.closed", value: "icon") { AppIconSettings() }
        }
        .frame(width: 540, height: 460)
    }
}

struct GeneralSettings: View {
    let workspace: Workspace

    var body: some View {
        Form {
            Section("Locations") {
                ForEach(workspace.locations) { location in
                    HStack {
                        Image(systemName: location.isICloudDrive ? "icloud" : "folder")
                            .foregroundStyle(Color.theme(Theme.accent))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.name)
                            Text(location.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { workspace.removeLocation(location.id) }
                    }
                }
                Button("Add Location…") { workspace.chooseLocation(iCloud: false) }
            }
            Section("New notes") {
                LabeledContent("Inbox") {
                    Text(workspace.locations.first.map { "\($0.name) › Inbox" } ?? "Add a location first")
                        .foregroundStyle(.secondary)
                }
                Text("Notes made with ⌘N go next to the note you have open, or into the folder you selected in the sidebar. Without either, they go to the Inbox.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Section("Search") {
                LabeledContent("Indexed") {
                    Text(workspace.index.isBuilding ? "Reading your files…" : "\(workspace.index.entries.count) files")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
