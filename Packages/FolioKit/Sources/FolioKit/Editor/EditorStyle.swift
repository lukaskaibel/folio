import AppKit

extension NSAttributedString.Key {
    /// Markdown punctuation that isn't drawn. `HiddenMode.untilRevealed` comes back next to the caret,
    /// `HiddenMode.always` never does.
    static let folioHidden = NSAttributedString.Key("folio.hidden")
    /// An `EditorObject` drawn in place of its character, on the first character of what it stands for.
    static let folioObject = NSAttributedString.Key("folio.object")
    /// A box drawn behind a run of text (code blocks, callouts, inline code, links to notes).
    static let folioDecoration = NSAttributedString.Key("folio.decoration")
    /// Where a click goes: a URL or a note.
    static let folioLink = NSAttributedString.Key("folio.link")
}

enum HiddenMode: Int {
    case untilRevealed = 1
    case always = 2
}

/// Fonts, colours and spacing of a note.
enum EditorStyle {
    static let bodySize: CGFloat = 15
    static let lineHeight: CGFloat = 24
    static let codeSize: CGFloat = 13
    static let codeLineHeight: CGFloat = 20
    static let contentWidth: CGFloat = 700
    static let listIndent: CGFloat = 24
    static let quoteIndent: CGFloat = 18
    static let codePadding: CGFloat = 14

    static let body = NSFont.systemFont(ofSize: bodySize)
    static let mono = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    static let inlineMono = NSFont.monospacedSystemFont(ofSize: bodySize * 0.88, weight: .regular)
    static let tiny = NSFont.systemFont(ofSize: 0.5)

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 28, weight: .bold)
        case 2: .systemFont(ofSize: 22, weight: .semibold)
        case 3: .systemFont(ofSize: 18, weight: .semibold)
        default: .systemFont(ofSize: 16, weight: .semibold)
        }
    }

    static func headingLineHeight(_ level: Int) -> CGFloat {
        switch level {
        case 1: 36
        case 2: 30
        case 3: 26
        default: 24
        }
    }

    static func headingSpacingBefore(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 14
        case 3: 10
        default: 8
        }
    }

    /// Lines of a fixed height, with the text in the middle of the line rather than at its bottom.
    static func paragraph(
        lineHeight: CGFloat = lineHeight,
        before: CGFloat = 0,
        after: CGFloat = 2,
        firstIndent: CGFloat = 0,
        indent: CGFloat = 0,
        tail: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = firstIndent
        style.headIndent = indent
        style.tailIndent = tail
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// For a line that only holds a picture or a rendered block: as tall as the thing in it.
    static func objectParagraph(before: CGFloat = 6, after: CGFloat = 8, indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    /// A line folded away inside a block that is drawn as a whole.
    static let collapsedParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }()

    /// Lifts text so it sits in the middle of a line taller than the font.
    static func baselineOffset(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        let natural = font.ascender - font.descender
        return max(0, (lineHeight - natural) / 2) - 1
    }

    /// The same font, bolder and/or slanted. Bold makes body text semibold and headings heavy.
    static func font(_ font: NSFont, bold: Bool = false, italic: Bool = false) -> NSFont {
        var result = font
        if bold {
            if font.isFixedPitch {
                result = .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
            } else {
                result = .systemFont(ofSize: font.pointSize, weight: weight(of: font) >= NSFont.Weight.semibold.rawValue - 0.01 ? .heavy : .semibold)
            }
        }
        if italic {
            let traits = result.fontDescriptor.symbolicTraits.union(.italic)
            result = NSFont(descriptor: result.fontDescriptor.withSymbolicTraits(traits), size: result.pointSize) ?? result
        }
        return result
    }

    static func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }
}
