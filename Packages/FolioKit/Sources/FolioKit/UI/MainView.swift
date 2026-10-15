import AppKit
import SwiftUI

/// The window: the welcome screen until there is a location, then the sidebar and the open file.
public struct RootView: View {
    @State private var workspace = Workspace.shared

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
        .background(Color.theme(Theme.window))
    }
}

struct MainView: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if workspace.isSidebarVisible {
                    SidebarColumn(workspace: workspace)
                        .frame(width: Theme.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ContentPanel(workspace: workspace)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, workspace.isSidebarVisible ? 0 : 8)
            }
            if workspace.isPaletteOpen {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        workspace.isPaletteOpen = false
                        workspace.paletteMode = .search
                    }
                VStack {
                    CommandPalette(workspace: workspace)
                        .padding(.top, 96)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if let toast = workspace.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.theme(Theme.text))
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.theme(Theme.popover)))
                        .overlay(Capsule().strokeBorder(Color.theme(Theme.popoverBorder)))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(Theme.quick, value: workspace.isPaletteOpen)
        .animation(Theme.spring, value: workspace.toast)
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

struct SidebarColumn: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                IconButton(symbol: "sidebar.left", help: "Hide sidebar (⌃⌘S)") {
                    withAnimation(Theme.spring) { workspace.isSidebarVisible = false }
                }
            }
            .frame(height: 44)
            .padding(.trailing, 8)
            HStack(spacing: 6) {
                Button {
                    workspace.paletteMode = .search
                    workspace.isPaletteOpen = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                        Text("Search")
                        Spacer()
                        Keycap("⌘K")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                    .padding(.leading, 8)
                    .padding(.trailing, 5)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.theme(Theme.control)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
                IconButton(symbol: "square.and.pencil", help: "New note (⌘N)") { workspace.newNote() }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            SidebarOutline(workspace: workspace)
                .padding(.horizontal, 4)
            Button {
                workspace.chooseLocation(iCloud: false)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12))
                    Text("Add location")
                    Spacer()
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Content

struct ContentPanel: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(workspace: workspace)
            Rectangle().fill(Color.theme(Theme.separator)).frame(height: 1)
            if let conflict = workspace.note?.conflict {
                ConflictBanner(conflict: conflict, workspace: workspace)
            }
            DocumentBody(workspace: workspace)
        }
        .background(Color.theme(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.theme(Theme.panelBorder)))
    }
}

struct DocumentBody: View {
    let workspace: Workspace

    var body: some View {
        Group {
            if let url = workspace.currentURL {
                if workspace.note != nil {
                    NoteEditorView(editor: workspace.editor)
                } else {
                    QuickLookView(url: url)
                        .id(url)
                }
            } else {
                EmptyState(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoteEditorView: NSViewRepresentable {
    let editor: EditorController

    func makeNSView(context: Context) -> NSView { editor.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct EmptyState: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.theme(Theme.faint))
            Text("Pick a note, or start a new one")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.theme(Theme.textSecondary))
            HStack(spacing: 14) {
                HStack(spacing: 4) { Keycap("⌘N"); Text("new note") }
                HStack(spacing: 4) { Keycap("⌘K"); Text("search") }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.theme(Theme.textTertiary))
        }
    }
}

struct HeaderBar: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            if !workspace.isSidebarVisible {
                Spacer().frame(width: 70)
                IconButton(symbol: "sidebar.left", help: "Show sidebar (⌃⌘S)") {
                    withAnimation(Theme.spring) { workspace.isSidebarVisible = true }
                }
            }
            IconButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: workspace.canGoBack) { workspace.goBack() }
            IconButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: workspace.canGoForward) { workspace.goForward() }
            Breadcrumb(workspace: workspace)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            if let url = workspace.currentURL {
                if workspace.note == nil {
                    Button("Open in \(defaultAppName(url))") { NSWorkspace.shared.open(url) }
                        .buttonStyle(OutlineButtonStyle())
                        .padding(.trailing, 6)
                }
                IconButton(symbol: workspace.isFavorite(url) ? "star.fill" : "star", help: workspace.isFavorite(url) ? "Remove from favorites" : "Add to favorites",
                           tint: workspace.isFavorite(url) ? Color.theme(Theme.accent) : nil) {
                    workspace.toggleFavorite(url)
                }
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .help("Share")
                Menu {
                    Button("Rename") { workspace.editor.focusTitle() }.disabled(workspace.note == nil)
                    Button("Move to…") {
                        workspace.paletteMode = .move(url)
                        workspace.isPaletteOpen = true
                    }
                    Button("Duplicate") { workspace.duplicate(url) }
                    Divider()
                    Button("Copy Link") { workspace.copyLink(url) }
                    Button("Show in Finder") { workspace.revealInFinder(url) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { workspace.trash(url) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .fixedSize()
                .help("More")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.headerHeight)
    }

    private func defaultAppName(_ url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "App" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct Breadcrumb: View {
    let workspace: Workspace

    var body: some View {
        let items = workspace.breadcrumb
        HStack(spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.theme(Theme.faint))
                }
                let isLast = index == items.count - 1
                Text(item.name)
                    .font(.system(size: 13, weight: isLast ? .medium : .regular))
                    .foregroundStyle(Color.theme(isLast ? Theme.text : Theme.textTertiary))
                    .lineLimit(1)
                    .onTapGesture {
                        if !isLast { workspace.sidebar?.reveal(item.url, select: true) }
                    }
            }
        }
    }
}

struct ConflictBanner: View {
    let conflict: NoteDocument.Conflict
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(Color.theme(Theme.warning))
            VStack(alignment: .leading, spacing: 1) {
                Text("This note changed on \(conflict.source) while you were editing it here.")
                    .font(.system(size: 13, weight: .semibold))
                Text("Nothing is lost until you choose.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.theme(Theme.textSecondary))
            }
            Spacer()
            Button("Keep this one") { workspace.resolveConflict(.keepThis) }.buttonStyle(OutlineButtonStyle())
            Button("Use the other") { workspace.resolveConflict(.takeOther) }.buttonStyle(OutlineButtonStyle())
            Button("Keep both") { workspace.resolveConflict(.keepBoth) }.buttonStyle(OutlineButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.theme(Theme.warning).opacity(0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.theme(Theme.warning).opacity(0.3)).frame(height: 1) }
    }
}

// MARK: - Controls

struct IconButton: View {
    var symbol: String
    var help: String
    var enabled = true
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint ?? Color.theme(enabled ? Theme.textSecondary : Theme.faint))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.theme(Theme.hover) : .clear))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(prominent ? Color.theme(Theme.panel) : Color.theme(Theme.text))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Color.theme(Theme.text) : Color.theme(Theme.panel)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prominent ? .clear : Color.theme(Theme.panelBorder)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.theme(Theme.accent))
                    .frame(width: 88, height: 88)
                Image(systemName: "doc.text")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 26)
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
                point("magnifyingglass", "Find anything", "⌘K searches names, notes and PDFs.")
                point("icloud", "On every device", "iCloud Drive keeps your Mac, iPhone and iPad in step.")
            }
            .frame(maxWidth: 820)
            .padding(.bottom, 48)
            Button {
                workspace.chooseLocation(iCloud: true)
            } label: {
                Label("Open iCloud Drive", systemImage: "icloud")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.theme(Theme.accent)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            Button("Choose another folder…") { workspace.chooseLocation(iCloud: false) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.theme(Theme.textSecondary))
                .padding(.top, 14)
            Spacer()
            Text("You can add more locations later from the sidebar. Folio only sees the folders you choose.")
                .font(.system(size: 12))
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.theme(Theme.panel))
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Color.theme(Theme.accent))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.theme(Theme.accent).opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(Color.theme(Theme.textSecondary)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
