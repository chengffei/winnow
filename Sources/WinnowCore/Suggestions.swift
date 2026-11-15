import Foundation

/// Guesses which texts in file names are clutter, by how many names share them.
public enum Suggestions {
    public struct Suggestion: Identifiable, Equatable, Sendable {
        public var id: String { text }
        public let text: String
        /// How many file names contain it.
        public let count: Int
    }

    static let bracketed = try! NSRegularExpression(pattern: #"[\[【(（《「『][^\[\]【】()（）《》「」『』]{1,40}[\]】)）》」』]"#)
    static let domain = try! NSRegularExpression(
        pattern: #"(?i)(?:www\.)?[a-z0-9-]{2,}\.(?:com|net|org|cc|tv|me|xyz|top|vip|club|info|la|co|cn|io)(?![a-z0-9])"#)
    static let separators = CharacterSet(charactersIn: " -_.@~|+")

    /// Texts found in at least `minimum` of `names`, most likely clutter first: bracketed tags, web addresses,
    /// then whatever the names start or end with up to a separator.
    public static func find(in names: [String], minimum: Int = 3, limit: Int = 40) -> [Suggestion] {
        var tags: [String: Int] = [:], affixes: [String: Int] = [:]
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            let whole = NSRange(stem.startIndex..., in: stem)
            var seen = Set<String>()
            for re in [bracketed, domain] {
                for m in re.matches(in: stem, range: whole) {
                    if let r = Range(m.range, in: stem), seen.insert(String(stem[r])).inserted { tags[String(stem[r]), default: 0] += 1 }
                }
            }
            // Up to four pieces from each end, cut at separators: "site.com@", "-HD", " 1080p".
            let cuts = stem.indices.filter { stem[$0].unicodeScalars.allSatisfy(separators.contains) }
            for cut in cuts.prefix(4) {
                let piece = String(stem[...cut])
                if piece.count >= 3, piece.count < stem.count, seen.insert(piece).inserted { affixes[piece, default: 0] += 1 }
            }
            for cut in cuts.suffix(4) {
                let piece = String(stem[cut...])
                if piece.count >= 3, piece.count < stem.count, seen.insert(piece).inserted { affixes[piece, default: 0] += 1 }
            }
        }
        func ranked(_ counts: [String: Int], atLeast: Int) -> [Suggestion] {
            counts.filter { $0.value >= atLeast }.map { Suggestion(text: $0.key, count: $0.value) }
                .sorted { ($0.count, $0.text.count, $1.text) > ($1.count, $1.text.count, $0.text) }
        }
        let top = ranked(tags, atLeast: minimum)
        // An ending shared by a few files is often just a series name, so ask for more of those.
        var rest = ranked(affixes, atLeast: max(minimum, 5))
        // Of pieces that grow out of one another with the same count, keep the longest; drop what a tag already covers.
        rest = rest.filter { s in
            !rest.contains { $0.count == s.count && $0.text.count > s.text.count && $0.text.contains(s.text) }
                && !top.contains { $0.text.contains(s.text.trimmingCharacters(in: separators)) }
        }
        return Array((top + rest).prefix(limit))
    }

    /// Suggestions for the files under `roots`.
    public static func find(roots: [String], subfolders: Bool = true) -> [Suggestion] {
        find(in: FileSearch.index(roots: roots, subfolders: subfolders).map(\.name))
    }
}
