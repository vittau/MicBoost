import Foundation

/// Numeric comparison of the installed version with a release tag
/// (docs/architecture.md "Verificação de atualizações").
public enum AppVersion {
    /// Components of a `vX.Y.Z` release tag; `nil` when the tag has another shape.
    public static func components(ofTag tag: String) -> [Int]? {
        guard tag.hasPrefix("v") else { return nil }
        return components(ofVersion: String(tag.dropFirst()))
    }

    /// Components of a `X.Y.Z` version; `nil` when it has another shape.
    public static func components(ofVersion version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }

    /// Version shown to the user for a release tag, without the leading `v`.
    public static func displayVersion(ofTag tag: String) -> String? {
        guard components(ofTag: tag) != nil else { return nil }
        return String(tag.dropFirst())
    }

    /// Whether `tag` names a version strictly newer than `installed`.
    public static func isNewer(tag: String, than installed: String) -> Bool {
        guard let candidate = components(ofTag: tag), let current = components(ofVersion: installed) else {
            return false
        }
        for (new, old) in zip(candidate, current) where new != old {
            return new > old
        }
        return false
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
