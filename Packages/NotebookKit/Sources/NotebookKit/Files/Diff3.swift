import Foundation

/// Line-based three-way merge, as in Issues: when a note changed on disk (iCloud, another app) while it had unsaved
/// edits here, both sides are kept if they touched different lines.
enum Diff3 {
    struct Hunk: Equatable {
        /// Lines of the base this hunk replaces. Empty for a pure insertion.
        var range: Range<Int>
        var lines: [Substring]
    }

    /// The merged text, or nil when both sides changed the same or neighbouring lines.
    static func merge(base: String, mine: String, theirs: String) -> String? {
        let base = normalize(base), mine = normalize(mine), theirs = normalize(theirs)
        if mine == theirs { return mine }
        if mine == base { return theirs }
        if theirs == base { return mine }

        let b = lines(base)
        let ours = hunks(base: b, other: lines(mine))
        let others = hunks(base: b, other: lines(theirs))

        var output: [Substring] = []
        var position = 0
        var i = 0, j = 0

        func apply(_ hunk: Hunk) {
            output += b[position..<hunk.range.lowerBound]
            output += hunk.lines
            position = hunk.range.upperBound
        }

        while i < ours.count || j < others.count {
            switch (i < ours.count ? ours[i] : nil, j < others.count ? others[j] : nil) {
            case let (a?, c?):
                if a == c {
                    apply(a)
                    i += 1
                    j += 1
                } else if a.range.lowerBound <= c.range.upperBound && c.range.lowerBound <= a.range.upperBound {
                    return nil
                } else if a.range.lowerBound < c.range.lowerBound {
                    apply(a)
                    i += 1
                } else {
                    apply(c)
                    j += 1
                }
            case let (a?, nil):
                apply(a)
                i += 1
            case let (nil, c?):
                apply(c)
                j += 1
            case (nil, nil):
                break
            }
        }
        output += b[position...]
        return output.joined(separator: "\n")
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The changes that turn `base` into `other`, as replacements of base line ranges. Lines the two share at the
    /// start and end are skipped first, so long notes with a small change stay quick.
    static func hunks(base: [Substring], other: [Substring]) -> [Hunk] {
        var prefix = 0
        while prefix < base.count, prefix < other.count, base[prefix] == other[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < other.count - prefix, base[base.count - 1 - suffix] == other[other.count - 1 - suffix] { suffix += 1 }
        let a = Array(base[prefix..<(base.count - suffix)])
        let o = Array(other[prefix..<(other.count - suffix)])
        let n = a.count, m = o.count
        if n == 0 && m == 0 { return [] }
        if n * m > 4_000_000 { return [Hunk(range: prefix..<(prefix + n), lines: o)] }
        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[at(i, j)] = a[i] == o[j] ? table[at(i + 1, j + 1)] + 1 : max(table[at(i + 1, j)], table[at(i, j + 1)])
                }
            }
        }
        var result: [Hunk] = []
        var i = 0, j = 0
        var startI = 0, startJ = 0
        func flush(_ endI: Int, _ endJ: Int) {
            if endI > startI || endJ > startJ {
                result.append(Hunk(range: (prefix + startI)..<(prefix + endI), lines: Array(o[startJ..<endJ])))
            }
        }
        while i < n && j < m {
            if a[i] == o[j] {
                flush(i, j)
                i += 1
                j += 1
                startI = i
                startJ = j
            } else if table[at(i + 1, j)] >= table[at(i, j + 1)] {
                i += 1
            } else {
                j += 1
            }
        }
        flush(n, m)
        return result
    }
}
