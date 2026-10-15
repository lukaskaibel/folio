import AppKit
import UniformTypeIdentifiers

/// Copy and paste as in Notes: a copied picture comes along as a picture, Markdown keeps its formatting, and pictures
/// and files dropped or pasted in are stored next to the note in `.assets`, hidden from the Finder.
extension EditorController {
    static let fragmentType = NSPasteboard.PasteboardType("com.lukaskbl.folio.fragment")

    /// Copies the selection as Markdown (and, for a single picture, as that file). Returns false when there is
    /// nothing selected.
    @discardableResult
    func copySelection(cut: Bool) -> Bool {
        let range = expandSelection(textView.selectedRange())
        guard range.length > 0 else { return false }
        let markdown = nsText.substring(with: range)
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        let fragment: [String: String] = ["markdown": markdown, "folder": folder?.path ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: fragment) { item.setData(data, forType: Self.fragmentType) }
        if let object = layoutManager.object(at: range.location), object.range(at: range.location) == range {
            switch object.kind {
            case .image(let url, _, _), .fileCard(let url, _):
                if let url { item.setString(url.absoluteString, forType: .fileURL) }
            default:
                break
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        if cut { replace(range, with: "", select: NSRange(location: range.location, length: 0), actionName: "Cut") }
        return true
    }

    /// Pastes or drops at `index` (or over the selection). Returns false to leave it to AppKit.
    @discardableResult
    func paste(from pasteboard: NSPasteboard, at index: Int?) -> Bool {
        let target = index.map { NSRange(location: $0, length: 0) } ?? textView.selectedRange()

        // Copied in Folio: Markdown, with its pictures copied along when it goes to a note in another folder.
        if let data = pasteboard.data(forType: Self.fragmentType),
           let fragment = try? JSONSerialization.jsonObject(with: data) as? [String: String], let markdown = fragment["markdown"] {
            let source = fragment["folder"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            let adjusted = copyAssets(in: markdown, from: source)
            replace(target, with: adjusted, select: NSRange(location: target.location + (adjusted as NSString).length, length: 0), actionName: "Paste")
            return true
        }

        // Files from the Finder or the sidebar.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var blocks: [String] = []
            var inline: [String] = []
            for url in urls {
                if url.pathExtension.lowercased() == "md", let link = noteLink(for: url) {
                    inline.append(link)
                } else if let stored = storeAsset(copying: url) {
                    let name = url.lastPathComponent
                    blocks.append(MarkdownStyler.isImageFile(url) ? "![](\(stored))" : "![\(name)](\(stored))")
                }
            }
            if !inline.isEmpty {
                let text = inline.joined(separator: " ")
                replace(target, with: text, select: NSRange(location: target.location + (text as NSString).length, length: 0), actionName: "Paste")
            }
            if !blocks.isEmpty { insertOnOwnLines(blocks.joined(separator: "\n"), at: inline.isEmpty ? target : textView.selectedRange()) }
            return !inline.isEmpty || !blocks.isEmpty
        }

        // A picture copied from another app.
        if pasteboard.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil,
           pasteboard.availableType(from: [.string]) == nil || pasteboard.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pasteboard), let stored = storeAsset(image: image) {
            insertOnOwnLines("![](\(stored))", at: target)
            return true
        }

        if let string = pasteboard.string(forType: .string) {
            let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            // A link pasted over selected text links that text.
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if target.length > 0, !trimmed.contains(" "), let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme),
               !nsText.substring(with: target).contains("\n") {
                let label = nsText.substring(with: target)
                let link = "[\(label)](\(trimmed))"
                replace(target, with: link, select: NSRange(location: target.location + (link as NSString).length, length: 0), actionName: "Add Link")
                return true
            }
            replace(target, with: normalized, select: NSRange(location: target.location + (normalized as NSString).length, length: 0), actionName: "Paste")
            return true
        }
        return false
    }

    /// Puts Markdown for a picture or file on lines of its own.
    func insertOnOwnLines(_ markdown: String, at range: NSRange) {
        var text = markdown
        let line = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        var lineEnd = line.upperBound
        if lineEnd > line.location, lineEnd <= storage.length, nsText.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        if range.location > line.location { text = "\n" + text }
        if range.upperBound < lineEnd { text += "\n" }
        replace(range, with: text, select: NSRange(location: range.location + (text as NSString).length, length: 0), actionName: "Insert")
    }

    // MARK: - Assets

    var assetsFolder: URL? { folder?.appendingPathComponent(".assets", isDirectory: true) }

    /// A path for Markdown: spaces and brackets encoded so the link holds together everywhere.
    static func markdownPath(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return ".assets/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
    }

    private func uniqueAssetURL(named name: String) -> URL? {
        guard let assets = assetsFolder else { return nil }
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = assets.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = assets.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Copies a file into `.assets` and returns its Markdown path.
    func storeAsset(copying url: URL) -> String? {
        if let assets = assetsFolder, url.deletingLastPathComponent().standardizedFileURL == assets.standardizedFileURL {
            return Self.markdownPath(url.lastPathComponent)
        }
        guard let destination = uniqueAssetURL(named: url.lastPathComponent) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], writingItemAt: destination, options: .forReplacing, error: nil) { from, to in
            copied = (try? FileManager.default.copyItem(at: from, to: to)) != nil
        }
        return copied ? Self.markdownPath(destination.lastPathComponent) : nil
    }

    /// Saves a pasted picture into `.assets` as PNG (screenshots, drawings) or JPEG (photos).
    func storeAsset(image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let isPhoto = bitmap.pixelsWide * bitmap.pixelsHigh > 1_500_000 && !bitmap.hasAlpha
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let note = delegate?.editorNoteName(self) ?? "Picture"
        let name = "\(note) \(formatter.string(from: Date())).\(isPhoto ? "jpg" : "png")"
        guard let destination = uniqueAssetURL(named: name),
              let data = isPhoto ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) : bitmap.representation(using: .png, properties: [:]) else { return nil }
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: nil) { url in
            written = (try? data.write(to: url)) != nil
        }
        return written ? Self.markdownPath(destination.lastPathComponent) : nil
    }

    /// Markdown copied from a note in another folder points at that folder's `.assets`: copy the files it uses
    /// here and point at the copies.
    private func copyAssets(in markdown: String, from source: URL?) -> String {
        guard let source, let folder, source.standardizedFileURL != folder.standardizedFileURL else { return markdown }
        guard let expression = try? NSRegularExpression(pattern: "\\]\\((\\.assets/[^)\\s]+)\\)") else { return markdown }
        var result = markdown
        let matches = expression.matches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length)).reversed()
        for match in matches {
            let path = (markdown as NSString).substring(with: match.range(at: 1))
            let decoded = path.removingPercentEncoding ?? path
            let file = source.appendingPathComponent(decoded)
            guard FileManager.default.fileExists(atPath: file.path), let stored = storeAsset(copying: file) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: stored)
        }
        return result
    }

    /// `[[Name]]` for a note dropped in from the sidebar or the Finder.
    private func noteLink(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return "[[\(name)]]"
    }
}
