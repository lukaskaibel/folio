import AppKit
import SwiftUI

/// Settings › App Icon: the notebook on Folio's icon, in the leather, ribbon and background you like.
struct AppIconSettings: View {
    @Bindable private var store = AppIconStore.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 36) {
                    preview(store.lightIcon, "Light")
                    preview(store.darkIcon, "Dark")
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                LabeledContent("Leather") {
                    SwatchRow(swatches: NotebookLook.leathers, color: $store.look.leather)
                }
                Picker("Elastic band", selection: $store.look.band) {
                    ForEach(NotebookLook.Band.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Ribbon") {
                    SwatchRow(swatches: NotebookLook.ribbons, color: $store.look.ribbon)
                }
                LabeledContent("Background") {
                    SwatchRow(swatches: NotebookLook.grounds, color: $store.look.ground)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Folio shows your notebook in the Dock while it’s open, in light or dark with your Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Standard") { store.reset() }
                        .disabled(store.look == .standard)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if store.lightIcon == nil { store.renderPreviews() }
        }
    }

    private func preview(_ image: NSImage?, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 88, height: 88)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App icon, \(caption.lowercased())")
    }
}

/// A row of colours to pick from, like the accent colours in System Settings, and a colour well for any other.
private struct SwatchRow: View {
    let swatches: [NotebookLook.Swatch]
    @Binding var color: NotebookColor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(swatches) { swatch in
                let selected = swatch.color == color
                Button {
                    color = swatch.color
                } label: {
                    Circle()
                        .fill(Color(nsColor: swatch.color.nsColor))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ColorPicker("Other colour", selection: Binding(
                get: { Color(nsColor: color.nsColor) },
                set: { color = NotebookColor(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Other colour")
        }
        // The row's label lines up with the middle of the colours, not their top.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}
