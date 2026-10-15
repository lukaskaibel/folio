import AppKit
import PDFKit
import SwiftUI

/// The window: the welcome screen until there is a location, then the sidebar, the open file and its outline.
public struct RootView: View {
    @State private var workspace = Workspace.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Group {
            if workspace.locations.isEmpty {
                WelcomeView(workspace: workspace)
            } else {
                MainView(workspace: workspace)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            // Opening a folder from a file window, or with this one closed, brings this window back.
            workspace.showWindow = { [openWindow] in openWindow(id: "main") }
        }
    }
}

/// A Mac window like the system's own: a sidebar of files, the note, and an inspector with the note's outline.
struct MainView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.columnVisibility) {
            SidebarOutline(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
                .toolbar {
                    ToolbarItem {
                        Button { workspace.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                            .help("New note (⌘N)")
                    }
                }
        } detail: {
            DetailColumn(workspace: workspace)
                .inspector(isPresented: $workspace.isOutlineVisible) {
                    OutlinePanel(workspace: workspace)
                        .inspectorColumnWidth(min: 200, ideal: 240, max: 360)
                }
                .toolbar { DocumentToolbar(workspace: workspace) }
                .toolbar(removing: .title)
        }
        .navigationTitle(workspace.currentTitle)
        .alert(conflictTitle, isPresented: Binding(get: { workspace.note?.conflict != nil }, set: { _ in }), presenting: workspace.note?.conflict) { _ in
            Button("Keep Both") { workspace.resolveConflict(.keepBoth) }
            Button("Keep This Version") { workspace.resolveConflict(.keepThis) }
            Button("Use the Other Version") { workspace.resolveConflict(.takeOther) }
        } message: { conflict in
            Text("It changed on \(conflict.source) while you were editing it here. Keep both to have the other version as a copy next to it.")
        }
    }

    private var conflictTitle: String {
        "“\(workspace.currentTitle)” was changed somewhere else."
    }
}

// MARK: - Toolbar

/// Back and forward on the left; formatting, sharing, more, search and the outline on the right.
struct DocumentToolbar: ToolbarContent {
    let workspace: Workspace

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { workspace.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!workspace.canGoBack)
                .help("Back")
            Button { workspace.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!workspace.canGoForward)
                .help("Forward")
        }
        // The note's name, once its title has scrolled up under the toolbar. At most so wide that a long name never
        // pushes the search field into the toolbar's overflow menu.
        ToolbarItem(placement: .navigation) {
            Text(workspace.currentTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.leading, 6)
                .opacity(workspace.currentURL != nil && (workspace.isTitleScrolledAway || workspace.note == nil) ? 1 : 0)
                .animation(Theme.quick, value: workspace.isTitleScrolledAway)
                .accessibilityAddTraits(.isHeader)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)
        if let url = workspace.currentURL {
            if workspace.note != nil {
                ToolbarItem { FormatMenu() }
                ToolbarSpacer(.fixed)
            } else {
                ToolbarItem {
                    Button("Open in \(defaultAppName(url))") { NSWorkspace.shared.open(url) }
                }
                ToolbarSpacer(.fixed)
            }
            ToolbarItemGroup {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Share")
                MoreMenu(workspace: workspace, url: url)
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            SearchFieldItem(controller: workspace.search)
                .frame(width: 190, height: 36)
                .padding(.horizontal, 6)
                .help("Search names, notes and PDFs (⌘F)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button {
                withAnimation(Theme.spring) { workspace.isOutlineVisible.toggle() }
            } label: {
                Label(workspace.isOutlineVisible ? "Hide Outline" : "Show Outline", systemImage: "sidebar.right")
            }
            .help(workspace.isOutlineVisible ? "Hide outline (⌃⌘I)" : "Show outline (⌃⌘I)")
        }
    }

    private func defaultAppName(_ url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "App" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// The formatting commands, as in Notes' Aa button. They go to the note, which keeps the caret.
struct FormatMenu: View {
    var body: some View {
        Menu {
            item("Title", #selector(MarkdownTextView.makeTitle(_:)))
            item("Heading", #selector(MarkdownTextView.makeHeading(_:)))
            item("Subheading", #selector(MarkdownTextView.makeSubheading(_:)))
            item("Body", #selector(MarkdownTextView.makeBody(_:)))
            Divider()
            item("Bold", #selector(MarkdownTextView.toggleBoldface(_:)), "bold")
            item("Italic", #selector(MarkdownTextView.toggleItalics(_:)), "italic")
            item("Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "strikethrough")
            item("Highlight", #selector(MarkdownTextView.toggleHighlight(_:)), "highlighter")
            item("Code", #selector(MarkdownTextView.toggleInlineCode(_:)), "chevron.left.forwardslash.chevron.right")
            item("Link", #selector(MarkdownTextView.addLink(_:)), "link")
            Divider()
            item("Checklist", #selector(MarkdownTextView.makeChecklist(_:)), "checklist")
            item("Bulleted List", #selector(MarkdownTextView.makeBulletedList(_:)), "list.bullet")
            item("Numbered List", #selector(MarkdownTextView.makeNumberedList(_:)), "list.number")
            item("Block Quote", #selector(MarkdownTextView.makeQuote(_:)), "text.quote")
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .help("Format")
    }

    private func item(_ title: String, _ action: Selector, _ symbol: String? = nil) -> some View {
        Button { NSApp.sendAction(action, to: nil, from: nil) } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
    }
}

struct MoreMenu: View {
    let workspace: Workspace
    let url: URL

    var body: some View {
        Menu {
            let favorite = workspace.isFavorite(url)
            Button { workspace.toggleFavorite(url) } label: {
                Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star")
            }
            Divider()
            Button { workspace.editor.focusTitle() } label: { Label("Rename", systemImage: "pencil") }
                .disabled(workspace.note == nil)
            MoveToMenu(workspace: workspace, url: url)
            Button { workspace.duplicate(url) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Divider()
            Button { workspace.copyLink(url) } label: { Label("Copy Link", systemImage: "link") }
            Button { workspace.revealInFinder(url) } label: { Label("Show in Finder", systemImage: "finder") }
            if workspace.note != nil {
                Divider()
                Menu {
                    Button("PDF…") { workspace.export(as: .pdf) }
                    Button("PNG Image…") { workspace.export(as: .png) }
                } label: {
                    Label("Export As", systemImage: "square.and.arrow.up.on.square")
                }
                Button { workspace.printNote() } label: { Label("Print…", systemImage: "printer") }
            }
            Divider()
            Button(role: .destructive) { workspace.trash(url) } label: { Label("Move to Trash", systemImage: "trash") }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }
}

/// Move To, as in Notes: every folder, indented under its location.
struct MoveToMenu: View {
    let workspace: Workspace
    let url: URL

    var body: some View {
        Menu {
            ForEach(workspace.moveTargets(for: url), id: \.location.id) { target in
                Section(target.location.name) {
                    ForEach(target.folders, id: \.url) { folder in
                        Button {
                            workspace.move(url, into: folder.url)
                        } label: {
                            Text(String(repeating: "    ", count: max(0, folder.depth)) + (folder.depth < 0 ? "Top Level" : folder.name))
                        }
                        .disabled(folder.url.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL)
                    }
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
    }
}

// MARK: - The note

struct DetailColumn: View {
    let workspace: Workspace

    var body: some View {
        Group {
            if let url = workspace.currentURL {
                if workspace.note != nil {
                    NoteEditorView(editor: workspace.editor)
                        .ignoresSafeArea(.container, edges: .top)
                } else {
                    // What Preview and QuickTime Player open, Folio draws itself; everything else is Quick Look's.
                    switch FileKind(url: url, isDirectory: false) {
                    case .pdf: PDFFileView(url: url).id(url)
                    case .image: PictureFileView(url: url).id(url)
                    case .video: VideoFileView(url: url).id(url)
                    default: QuickLookView(url: url).id(url)
                    }
                }
            } else {
                EmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(Theme.panel).ignoresSafeArea())
        .overlay {
            SwipeAnchor(swiper: workspace.pages)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
    }
}

/// The note fills the column and scrolls under the toolbar; AppKit starts it just below.
struct NoteEditorView: NSViewRepresentable {
    let editor: EditorController

    func makeNSView(context: Context) -> NSView { editor.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct EmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Note Open", systemImage: "doc.text")
        } description: {
            Text("Pick a note in the sidebar, press ⌘N for a new one, or ⌘F to search.")
        }
    }
}

// MARK: - Outline

/// The inspector: the note's headings, the one you are reading selected, and how long the note is.
struct OutlinePanel: View {
    let workspace: Workspace

    var body: some View {
        if workspace.note == nil {
            if let url = workspace.currentURL {
                FileInfoPanel(url: url, place: workspace.index.entry(for: url)?.place ?? "")
                    .id(url)
            } else {
                ContentUnavailableView {
                    Label("No Outline", systemImage: "list.bullet.indent")
                } description: {
                    Text("Notes show their headings here.")
                }
            }
        } else {
            let base = workspace.outline.map(\.level).min() ?? 1
            ScrollViewReader { proxy in
                List(selection: selection) {
                    Section("Outline") {
                        Text(workspace.currentTitle)
                            .fontWeight(.medium)
                            .tag(-1)
                            .id(-1)
                        ForEach(workspace.outline) { heading in
                            Text(heading.title)
                                .lineLimit(2)
                                .padding(.leading, CGFloat(heading.level - base + 1) * 12)
                                .tag(heading.id)
                                .id(heading.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: workspace.currentHeading) { _, current in
                    withAnimation(Theme.quick) { proxy.scrollTo(current ?? -1) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("\(workspace.stats.words.formatted()) \(workspace.stats.words == 1 ? "word" : "words") · \(workspace.stats.readingMinutes) min read")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
    }

    /// The section you are reading, and the one you pick to go to.
    private var selection: Binding<Int?> {
        Binding(get: { workspace.currentHeading ?? -1 }, set: { id in
            guard let id else { return }
            workspace.editor.scroll(to: workspace.outline.first { $0.id == id })
        })
    }
}

/// For a PDF, picture or any other file: what it is, as the Finder's Get Info has it.
private struct FileInfoPanel: View {
    let url: URL
    let place: String
    @State private var facts: [(String, String)] = []

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section("Info") {
                ForEach(facts, id: \.0) { fact in
                    LabeledContent(fact.0, value: fact.1)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: url) { facts = await Self.facts(for: url, place: place) }
    }

    private static func facts(for url: URL, place: String) async -> [(String, String)] {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
        var facts: [(String, String)] = []
        if let kind = values?.localizedTypeDescription { facts.append(("Kind", kind)) }
        if let size = values?.fileSize { facts.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        let detail = await Task.detached(priority: .utility) { () -> (String, String)? in
            if url.pathExtension.lowercased() == "pdf", let pages = PDFDocument(url: url)?.pageCount {
                return ("Pages", "\(pages)")
            }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                // As the picture shows: orientations 5 to 8 turn it a quarter.
                let turned = (properties[kCGImagePropertyOrientation] as? UInt32 ?? 1) >= 5
                return ("Dimensions", turned ? "\(height) × \(width)" : "\(width) × \(height)")
            }
            return nil
        }.value
        if let detail { facts.append(detail) }
        if let created = values?.creationDate { facts.append(("Created", created.formatted(date: .abbreviated, time: .shortened))) }
        if let modified = values?.contentModificationDate { facts.append(("Modified", modified.formatted(date: .abbreviated, time: .shortened))) }
        if !place.isEmpty { facts.append(("Where", place)) }
        return facts
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .padding(.bottom, 18)
            Text("Your notes live in your folders")
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 10)
            Text("Folio opens the folders you already use. Notes are Markdown files next to your PDFs and photos, and everything else opens in Quick Look.")
                .font(.system(size: 15))
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.bottom, 40)
            HStack(alignment: .top, spacing: 28) {
                point("folder", "Plain files", "Every note is a .md file. Move it in Finder, open it anywhere.")
                point("magnifyingglass", "Find anything", "⌘F searches names, notes and PDFs.")
                point("icloud", "On every device", "iCloud Drive keeps your Mac, iPhone and iPad in step.")
            }
            .frame(maxWidth: 820)
            .padding(.bottom, 48)
            Button {
                workspace.chooseLocation(iCloud: true)
            } label: {
                Label("Open iCloud Drive", systemImage: "icloud")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            Button("Choose another folder…") { workspace.chooseLocation(iCloud: false) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .padding(.top, 14)
            Spacer()
            Text("You can add more folders later with File › Add Location. Folio only sees the folders you choose.")
                .font(.system(size: 12))
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(Theme.panel).ignoresSafeArea())
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// A line of what Folio does, as on the system's own welcome screens.
    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
