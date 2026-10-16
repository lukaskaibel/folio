#if os(macOS)
import AppKit
import SwiftUI

/// The app's window, its settings and its menus. The app target only has to show this scene.
public struct NotebookScene: Scene {
    @State private var workspace = Workspace.shared
    @State private var settings = NotebookSettings.shared

    public init() {
        AppIconTip.configure()
    }

    public var body: some Scene {
        Window("Notebook", id: "main") {
            RootView()
                .onAppear {
                    workspace.start()
                    AppIconStore.shared.start()
                    #if DEBUG
                    DebugRemote.startIfRequested(workspace: workspace)
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in workspace.saveAll() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in workspace.saveAll(quitting: true) }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .importExport) {
                Menu("Export As") {
                    Button("PDF…") { workspace.export(as: .pdf) }
                        .keyboardShortcut("e", modifiers: [.command, .option])
                    Button("PNG Image…") { workspace.export(as: .png) }
                }
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { workspace.printNote() }
                    .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") { workspace.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(workspace.locations.isEmpty)
                Button("New Folder") { workspace.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workspace.locations.isEmpty)
                Button("Open…") { FileWindows.shared.choose() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(workspace.recentURLs.prefix(10), id: \.self) { url in
                        Button(FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent) {
                            workspace.open(url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") { workspace.clearRecents() }
                        .disabled(workspace.recentURLs.isEmpty)
                }
                Divider()
                if let url = workspace.currentURL {
                    MoveToMenu(workspace: workspace, url: url)
                }
                Divider()
                Button("Add Location…") { workspace.chooseLocation(iCloud: false) }
            }
            // The window's own sidebar item, bound to the same state as the toolbar button.
            CommandGroup(replacing: .sidebar) {
                Button(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation(Theme.spring) { workspace.isSidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(workspace.locations.isEmpty)
                Button(workspace.isOutlineVisible ? "Hide Outline" : "Show Outline") {
                    withAnimation(Theme.spring) { workspace.isOutlineVisible.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(workspace.locations.isEmpty)
                Divider()
                Toggle("Show Only Notes", isOn: $settings.showsOnlyNotes)
                Toggle("Dim Files That Aren’t Notes", isOn: $settings.dimsOtherFiles)
                Toggle("Keep Folders on Top", isOn: $settings.foldersFirst)
                // The Finder's shortcut for its hidden files.
                Button(workspace.showsAllHiddenFolders ? "Hide Hidden Folders" : "Show Hidden Folders") { workspace.toggleAllHiddenFolders() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!workspace.hasHiddenFolders)
                Divider()
                Button("Bigger") { settings.changeTextSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller") { settings.changeTextSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { settings.typography.size = 15 }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Search…") { workspace.search.focus() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Back") { workspace.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!workspace.canGoBack)
                Button("Forward") { workspace.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!workspace.canGoForward)
            }
            CommandMenu("Format") {
                formatButton("Bold", #selector(MarkdownTextView.toggleBoldface(_:)), "b", .command)
                formatButton("Italic", #selector(MarkdownTextView.toggleItalics(_:)), "i", .command)
                formatButton("Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
                formatButton("Highlight", #selector(MarkdownTextView.toggleHighlight(_:)), "h", [.command, .control])
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
                Button(workspace.isDrawing ? "Stop Drawing" : "Drawing") { workspace.editor.toggleDrawing() }
                    .disabled(workspace.note == nil)
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

/// Settings, in the system's tabbed window: where notes live, how they are set, what the sidebar shows, the app icon.
struct SettingsView: View {
    let workspace: Workspace
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(workspace: workspace) }
            Tab("Text", systemImage: "textformat", value: "text") { TextSettings() }
            Tab("Sidebar", systemImage: "sidebar.left", value: "sidebar") { SidebarSettings() }
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
                    Text(workspace.index.isBuilding ? "Reading your files…" : "\(workspace.index.count) files")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
