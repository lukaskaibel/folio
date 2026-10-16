#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Something drawn in place of Markdown: a checkbox, a picture, a rendered table. It sits on the first character of
/// the Markdown it stands for; that character is laid out as an empty box the object's size and the rest of the
/// Markdown is hidden, so the source stays in the text exactly as it is in the file.
final class EditorObject: NSObject {
    enum Kind {
        case bullet(level: Int)
        case checkbox(checked: Bool)
        case quoteBar
        /// The front of a link to a note: its icon.
        case chipLead(icon: ChipIcon)
        /// The end of a link to a note: a little room after the name.
        case chipTrail
        case image(url: URL?, source: String, inline: Bool)
        /// A picture with its strokes next to it (`DrawingFile`): drawn from them, and drawn in.
        case drawing(url: URL)
        case fileCard(url: URL?, name: String)
        case noteEmbed(target: String, url: URL?)
        case horizontalRule
        case table(TableModel)
        case mermaid(source: String)
        case mathBlock(tex: String)
        case mathInline(tex: String)
        case callout(type: String, label: String?)
        case frontmatter(count: Int)
        /// After a link's text: a pencil that edits where it goes.
        case linkEdit
    }

    enum ChipIcon {
        case note, file, missing, embed
    }

    let kind: Kind
    /// How far before the object's character the Markdown it stands for starts, and how long it is. Relative, so
    /// the object stays right when text before it moves it along.
    let offset: Int
    let length: Int
    /// Shown as its Markdown when the caret is next to it (math, a rule, a callout's type).
    let revealable: Bool

    /// `range` is where the Markdown is now; `at` is the character the object goes on.
    init(_ kind: Kind, range: NSRange, at index: Int? = nil, revealable: Bool = false) {
        self.kind = kind
        self.offset = (index ?? range.location) - range.location
        self.length = range.length
        self.revealable = revealable
    }

    /// The Markdown the object stands for, given the character it is on.
    func range(at index: Int) -> NSRange {
        NSRange(location: index - offset, length: length)
    }

    /// Takes a line of its own and the whole width of the text.
    var isBlock: Bool {
        switch kind {
        case .image(_, _, let inline): !inline
        case .drawing, .fileCard, .noteEmbed, .horizontalRule, .table, .mermaid, .mathBlock, .frontmatter: true
        default: false
        }
    }

    /// The caret goes around it and a selection takes all of it or none: the parts of a list item's prefix,
    /// pictures, links to notes.
    var isAtomic: Bool {
        switch kind {
        case .mathInline, .horizontalRule, .callout: false
        default: true
        }
    }

    var signature: String {
        switch kind {
        case .bullet(let level): "bullet\(level)"
        case .checkbox(let checked): "check\(checked)"
        case .quoteBar: "quote"
        case .chipLead(let icon): "lead\(icon)"
        case .chipTrail: "trail"
        case .image(let url, let source, let inline): "image\(url?.path ?? source)\(inline)"
        case .drawing(let url): "drawing\(url.path)"
        case .fileCard(let url, let name): "file\(url?.path ?? name)"
        case .noteEmbed(let target, _): "embed\(target)"
        case .horizontalRule: "hr"
        case .table(let model): "table\(model.signature)"
        case .mermaid(let source): "mermaid\(source)"
        case .mathBlock(let tex): "math\(tex)"
        case .mathInline(let tex): "imath\(tex)"
        case .callout(let type, let label): "callout\(type)\(label ?? "")"
        case .frontmatter(let count): "front\(count)"
        case .linkEdit: "linkEdit"
        }
    }
}

/// A box drawn behind text. One instance covers all the text it goes around, so where it starts and ends is the
/// run of characters that carry this very instance; that moves along with the text when text before it changes.
final class Decoration: NSObject {
    enum Kind: Equatable {
        case codeBlock(language: String, active: Bool, preview: Preview? = nil)
        case callout(type: String)
        case inlineCode
        case chip(resolved: Bool)
        case highlight
    }

    /// What a diagram or formula being edited looks like, drawn under the box with its source.
    enum Preview: Equatable {
        case diagram(source: String)
        case math(tex: String)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// Where a click on a link goes. Like a decoration, one instance covers the whole link.
public final class LinkTarget: NSObject {
    public enum Kind: Equatable {
        case url(String)
        case note(String)
        case file(URL)
    }

    public let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

extension NSAttributedString {
    /// The run of characters around `index` that carry this very object for `key`.
    func extent(of key: NSAttributedString.Key, at index: Int) -> (value: AnyObject, range: NSRange)? {
        guard index >= 0, index < length else { return nil }
        var range = NSRange()
        guard let value = attribute(key, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: length)) as AnyObject? else { return nil }
        return (value, range)
    }
}

/// Callout types, as GitHub and Obsidian name them.
enum CalloutStyle {
    static func color(_ type: String) -> NSColor {
        switch type {
        case "tip", "hint", "success", "check", "done": Theme.positive
        case "important", "abstract", "summary", "tldr", "example": Theme.purple
        case "warning", "caution", "attention", "question", "help", "faq": Theme.warning
        case "danger", "error", "failure", "fail", "missing", "bug": Theme.red
        default: Theme.accent
        }
    }

    static func symbol(_ type: String) -> String {
        switch type {
        case "tip", "hint": "lightbulb"
        case "success", "check", "done": "checkmark.circle"
        case "important": "exclamationmark.bubble"
        case "abstract", "summary", "tldr": "list.bullet.rectangle"
        case "example": "list.bullet"
        case "warning", "attention": "exclamationmark.triangle"
        case "caution", "danger", "error": "exclamationmark.octagon"
        case "failure", "fail", "missing": "xmark.circle"
        case "bug": "ladybug"
        case "question", "help", "faq": "questionmark.circle"
        case "quote", "cite": "quote.opening"
        default: "info.circle"
        }
    }

    static func title(_ type: String) -> String {
        type.prefix(1).uppercased() + type.dropFirst()
    }
}
