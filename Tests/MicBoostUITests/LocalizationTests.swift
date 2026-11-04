import Foundation
import Testing

/// Guards the string catalogs of docs/ui.md "Idiomas": every key passed to `localized(...)` or
/// `String(localized:)` in the UI and app sources must exist in both `.strings` files, the two
/// catalogs must have the same keys, and a translation must keep the placeholders of its key.
struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sourceDirectories = ["Sources/MicBoostUI", "Sources/MicBoostApp"]
    private static let languages = ["en", "pt-BR"]

    @Test func everyKeyUsedInTheAppIsInBothCatalogs() throws {
        let used = try Self.keysUsedInSources()
        // A near-empty scan means the patterns stopped matching the sources, not that the
        // app lost its strings.
        #expect(used.count > 40, "The source scan found only \(used.count) keys")
        for language in Self.languages {
            let catalog = try Self.catalog(language)
            let missing = used.subtracting(catalog.keys).sorted()
            #expect(missing.isEmpty, "Keys missing from \(language).lproj: \(missing.joined(separator: ", "))")
        }
    }

    @Test func bothCatalogsShareTheSameKeys() throws {
        let english = Set(try Self.catalog("en").keys)
        let portuguese = Set(try Self.catalog("pt-BR").keys)
        #expect(
            english.subtracting(portuguese).isEmpty, "Only in en.lproj: \(english.subtracting(portuguese).sorted())")
        #expect(
            portuguese.subtracting(english).isEmpty, "Only in pt-BR.lproj: \(portuguese.subtracting(english).sorted())")
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        for language in Self.languages {
            let catalog = try Self.catalog(language)
            for (key, value) in catalog {
                #expect(!value.isEmpty, "\(language): empty value for \(key)")
                #expect(
                    Self.placeholders(in: value) == Self.placeholders(in: key),
                    "\(language): placeholders differ for \(key)")
            }
        }
    }

    // MARK: - Catalogs

    private static func catalog(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Sources/MicBoostUI/Localization/\(language).lproj/Localizable.strings")
        return parseStrings(try String(contentsOfFile: url.path, encoding: .utf8))
    }

    /// One `"key" = "value";` per line, as the catalogs are written.
    private static func parseStrings(_ text: String) -> [String: String] {
        var catalog: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.drop { $0 == " " || $0 == "\t" }
            guard let (key, afterKey) = quoted(content) else { continue }
            let assignment = afterKey.drop { $0 == " " || $0 == "\t" }
            guard assignment.first == "=" else { continue }
            let valueText = assignment.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard let (value, _) = quoted(valueText) else { continue }
            catalog[key] = value
        }
        return catalog
    }

    /// Reads the string literal at the start of `text` and returns it with the rest of the text.
    private static func quoted(_ text: Substring) -> (String, Substring)? {
        guard text.first == "\"" else { return nil }
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                guard let (escaped, next) = escapedCharacter(in: text, at: index) else { return nil }
                value.append(escaped)
                index = next
            } else if character == "\"" {
                return (value, text[text.index(after: index)...])
            } else {
                value.append(character)
                index = text.index(after: index)
            }
        }
        return nil
    }

    private static func escapedCharacter(in text: Substring, at index: String.Index) -> (Character, String.Index)? {
        let escaped = text.index(after: index)
        guard escaped < text.endIndex else { return nil }
        let character: Character
        switch text[escaped] {
        case "n": character = "\n"
        case "t": character = "\t"
        case "\\": character = "\\"
        case "\"": character = "\""
        default: character = text[escaped]
        }
        return (character, text.index(after: escaped))
    }

    private static func placeholders(in text: String) -> [String] {
        let modifiers: Set<Character> = Set("-+ #0123456789.lhqLzjt".map { $0 })
        let conversions: Set<Character> = Set("@diouxXeEfgGcsSpaA".map { $0 })
        var found: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "%" else {
                index = text.index(after: index)
                continue
            }
            var end = text.index(after: index)
            while end < text.endIndex && modifiers.contains(text[end]) {
                end = text.index(after: end)
            }
            guard end < text.endIndex else { break }
            if conversions.contains(text[end]) {
                found.append(String(text[index...end]))
            }
            index = text.index(after: end)
        }
        return found.sorted()
    }

    // MARK: - Sources

    private static func keysUsedInSources() throws -> Set<String> {
        var used: Set<String> = []
        for directory in sourceDirectories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOfFile: url.path, encoding: .utf8)
                used.formUnion(keys(inSource: stripComments(source)))
            }
        }
        return used
    }

    /// Keys are the string literals passed to `localized(...)` and to `String(localized:)`.
    private static func keys(inSource source: String) -> Set<String> {
        var keys: Set<String> = []
        var searchStart = source.startIndex
        while let range = source.range(of: "localized(", range: searchStart..<source.endIndex) {
            searchStart = range.upperBound
            // The declaration of the helper itself takes no literal key.
            guard !source[..<range.lowerBound].hasSuffix("func ") else { continue }
            let open = source.index(before: range.upperBound)
            guard let close = matchingParen(in: source, from: open) else { continue }
            keys.formUnion(literals(in: source[source.index(after: open)..<close]))
        }
        searchStart = source.startIndex
        while let range = source.range(of: "String(localized:", range: searchStart..<source.endIndex) {
            searchStart = range.upperBound
            let open = source[..<range.lowerBound].lastIndex(of: "(") ?? range.lowerBound
            guard let close = matchingParen(in: source, from: open) else { continue }
            keys.formUnion(literals(in: source[range.upperBound..<close]))
        }
        return keys
    }

    private static func matchingParen(in source: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        var inString = false
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if character == "\\" {
                    index = source.index(after: index)
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            guard index < source.endIndex else { return nil }
            index = source.index(after: index)
        }
        return nil
    }

    private static func literals(in text: Substring) -> [String] {
        var literals: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if let (value, rest) = quoted(text[index...]) {
                literals.append(value)
                index = rest.startIndex
            } else {
                index = text.index(after: index)
            }
        }
        return literals
    }

    private static func stripComments(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        while index < source.endIndex {
            let character = source[index]
            if inString {
                result.append(character)
                if character == "\\" {
                    let next = source.index(after: index)
                    if next < source.endIndex {
                        result.append(source[next])
                        index = source.index(after: next)
                        continue
                    }
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
            } else if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
            } else if source[index...].hasPrefix("//") {
                while index < source.endIndex && source[index] != "\n" {
                    index = source.index(after: index)
                }
            } else if source[index...].hasPrefix("/*") {
                while index < source.endIndex && !source[index...].hasPrefix("*/") {
                    index = source.index(after: index)
                }
                index = index < source.endIndex ? source.index(index, offsetBy: 2) : index
            } else {
                result.append(character)
                index = source.index(after: index)
            }
        }
        return result
    }
}
