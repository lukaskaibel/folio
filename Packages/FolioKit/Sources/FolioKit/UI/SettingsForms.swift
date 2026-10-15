import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The typeface, size, line spacing and width of notes, with a sample set as you choose.
struct TextSettings: View {
    @Bindable private var settings = FolioSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $settings.typography.face) {
                    ForEach(Typography.Face.allCases) { face in Text(face.name).tag(face) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.typography.size, in: Typography.sizes, step: 1)
                        Text("\(Int(settings.typography.size)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Line spacing", selection: $settings.typography.spacing) {
                    ForEach(Typography.Spacing.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                if showsWidth {
                    Picker("Line width", selection: $settings.typography.width) {
                        ForEach(Typography.Width.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section("Preview") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Rise of Rococo")
                        .font(Font(EditorStyle.headingFont(2)))
                    Text("Emerging from the grandeur of Baroque, Rococo offered something more intimate and playful.")
                        .font(Font(EditorStyle.body))
                        .lineSpacing(EditorStyle.lineHeight - EditorStyle.bodySize * 1.2)
                }
                .padding(.vertical, 4)
                .id(settings.typography)
            }
        }
        .formStyle(.grouped)
    }

    /// On the iPhone the text is as wide as the screen, whatever the setting.
    private var showsWidth: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }
}

struct SidebarSettings: View {
    @Bindable private var settings = FolioSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show only notes", isOn: $settings.showsOnlyNotes)
                Toggle("Dim files that aren’t notes", isOn: $settings.dimsOtherFiles)
                    .disabled(settings.showsOnlyNotes)
                Toggle("Keep folders on top", isOn: $settings.foldersFirst)
            } footer: {
                Text("PDFs, pictures and other files still open from search and from links in your notes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
