import Foundation

/// Account only for leading Markdown heading syntax removed by the desktop title.
/// Never use substring/fuzzy matching: normalized title collisions remain ambiguous.
enum ChatTitleIdentity {
    static func key(_ title: String) -> String {
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}\u{2060}"))
        var text = title.trimmingCharacters(in: padding)
        let candidate = text.hasPrefix("\\#") ? String(text.dropFirst()) : text
        let marks = candidate.prefix(while: { $0 == "#" })
        if (1...6).contains(marks.count) {
            let rest = candidate.dropFirst(marks.count)
            if rest.first == " " || rest.first == "\t" {
                text = String(rest).trimmingCharacters(in: padding)
            }
        }
        return text
    }
    static func matches(_ displayed: String, _ saved: String) -> Bool {
        let key = key(saved)
        return !key.isEmpty && self.key(displayed) == key
    }
    static func isUnique(_ title: String, among titles: [String]) -> Bool {
        let key = key(title)
        return !key.isEmpty && titles.filter { self.key($0) == key }.count == 1
    }
}
