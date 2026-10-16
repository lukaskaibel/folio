#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Colours for code blocks: comments, strings, numbers, keywords and type names, from one regular expression per
/// language family. Light on purpose; it only has to make code easier to read, not to understand it.
enum CodeHighlighter {
    enum Token {
        case keyword, string, comment, number, type
    }

    static func color(_ token: Token) -> NSColor {
        switch token {
        case .keyword: NSColor(light: 0x8B3FC8, dark: 0xC792EA)
        case .string: NSColor(light: 0x2F8F5B, dark: 0x8BD49C)
        case .comment: Theme.textTertiary
        case .number: NSColor(light: 0xB86A12, dark: 0xF0A05A)
        case .type: NSColor(light: 0x2F72B5, dark: 0x7FB5E8)
        }
    }

    private struct Grammar {
        var lineComment: [String]
        var blockComment: (String, String)?
        var strings: [Character]
        var keywords: Set<String>
        var types: Bool
    }

    private static let cLikeKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "func", "function",
        "let", "var", "const", "class", "struct", "enum", "protocol", "interface", "extension", "import", "export", "from",
        "public", "private", "internal", "fileprivate", "static", "final", "override", "init", "deinit", "self", "Self",
        "super", "this", "new", "true", "false", "nil", "null", "undefined", "try", "catch", "throw", "throws", "async",
        "await", "in", "is", "as", "guard", "defer", "where", "typealias", "some", "any", "mutating", "inout", "lazy",
        "weak", "unowned", "package", "fn", "impl", "trait", "pub", "mut", "use", "mod", "match", "loop", "type", "go",
        "chan", "select", "range", "map", "fun", "val", "object", "when", "void", "int", "float", "double", "char", "long",
        "bool", "boolean", "string", "typeof", "instanceof", "yield", "extends", "implements", "with", "of", "delete",
    ]

    private static let scriptKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "return", "import", "from",
        "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass", "break", "continue", "None", "True",
        "False", "self", "async", "await", "global", "nonlocal", "end", "do", "then", "fi", "done", "case", "esac",
        "function", "local", "echo", "export", "module", "require", "unless", "until", "begin", "rescue", "ensure", "nil",
    ]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create",
        "table", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
        "limit", "offset", "as", "distinct", "null", "is", "in", "like", "primary", "key", "index", "union", "all", "case",
        "when", "then", "else", "end", "with", "returning", "default", "references", "foreign",
    ]

    private static func grammar(for language: String) -> Grammar? {
        switch language {
        case "swift", "js", "javascript", "ts", "typescript", "jsx", "tsx", "c", "cpp", "c++", "objc", "objective-c", "java",
             "kotlin", "kt", "go", "rust", "rs", "cs", "csharp", "dart", "scala", "php", "json", "jsonc":
            Grammar(lineComment: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'", "`"], keywords: cLikeKeywords, types: true)
        case "python", "py", "ruby", "rb", "sh", "bash", "zsh", "shell", "console", "yaml", "yml", "toml", "r", "perl",
             "make", "makefile", "dockerfile", "ini", "conf":
            Grammar(lineComment: ["#"], blockComment: nil, strings: ["\"", "'"], keywords: scriptKeywords, types: false)
        case "sql", "lua", "haskell", "hs":
            Grammar(lineComment: ["--"], blockComment: ("/*", "*/"), strings: ["\"", "'"], keywords: sqlKeywords, types: false)
        case "html", "xml", "svg", "markdown", "md", "vue":
            Grammar(lineComment: [], blockComment: ("<!--", "-->"), strings: ["\""], keywords: [], types: false)
        case "css", "scss", "less":
            Grammar(lineComment: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'"], keywords: [], types: false)
        case "":
            nil
        default:
            Grammar(lineComment: ["//", "#"], blockComment: ("/*", "*/"), strings: ["\"", "'"], keywords: cLikeKeywords, types: true)
        }
    }

    private static var expressions: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func expression(for language: String, grammar: Grammar) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = expressions[language] { return cached }
        var parts: [String] = []
        var comments: [String] = grammar.lineComment.map { NSRegularExpression.escapedPattern(for: $0) + "[^\\n]*" }
        if let block = grammar.blockComment {
            comments.append(NSRegularExpression.escapedPattern(for: block.0) + "[\\s\\S]*?(?:" + NSRegularExpression.escapedPattern(for: block.1) + "|$)")
        }
        if !comments.isEmpty { parts.append("(?<comment>" + comments.joined(separator: "|") + ")") }
        let strings = grammar.strings.map { quote -> String in
            let q = NSRegularExpression.escapedPattern(for: String(quote))
            return q + "(?:\\\\.|[^\\\\" + q + "\\n])*" + q
        }
        if !strings.isEmpty { parts.append("(?<string>" + strings.joined(separator: "|") + ")") }
        parts.append("(?<number>\\b(?:0x[0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b)")
        if !grammar.keywords.isEmpty {
            parts.append("(?<keyword>\\b(?:" + grammar.keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b)")
        }
        if grammar.types { parts.append("(?<type>\\b[A-Z][A-Za-z0-9_]*\\b)") }
        let options: NSRegularExpression.Options = grammar.keywords == sqlKeywords ? [.caseInsensitive] : []
        let expression = try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: options)
        expressions[language] = expression
        return expression
    }

    static func tokens(in code: String, language: String) -> [(NSRange, Token)] {
        guard let grammar = grammar(for: language), let expression = expression(for: language, grammar: grammar) else { return [] }
        var result: [(NSRange, Token)] = []
        // Only the groups the expression has: asking for any other throws.
        var names: [(String, Token)] = []
        if !grammar.lineComment.isEmpty || grammar.blockComment != nil { names.append(("comment", .comment)) }
        if !grammar.strings.isEmpty { names.append(("string", .string)) }
        names.append(("number", .number))
        if !grammar.keywords.isEmpty { names.append(("keyword", .keyword)) }
        if grammar.types { names.append(("type", .type)) }
        expression.enumerateMatches(in: code, range: NSRange(location: 0, length: (code as NSString).length)) { match, _, _ in
            guard let match else { return }
            for (name, token) in names {
                let range = match.range(withName: name)
                if range.location != NSNotFound, range.length > 0 {
                    result.append((range, token))
                    break
                }
            }
        }
        return result
    }
}
