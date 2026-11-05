import Foundation
import Testing

@testable import MicBoostCore

/// Version comparison of docs/architecture.md "Verificação de atualizações": numeric per
/// component, only a strictly newer tag counts, and a tag outside `vX.Y.Z` is ignored.
struct AppVersionTests {
    @Test func newerPatchMinorAndMajorAreNewer() {
        #expect(AppVersion.isNewer(tag: "v1.2.4", than: "1.2.3"))
        #expect(AppVersion.isNewer(tag: "v1.3.0", than: "1.2.9"))
        #expect(AppVersion.isNewer(tag: "v2.0.0", than: "1.99.99"))
    }

    @Test func equalAndOlderVersionsAreNotNewer() {
        #expect(!AppVersion.isNewer(tag: "v1.2.3", than: "1.2.3"))
        #expect(!AppVersion.isNewer(tag: "v1.2.2", than: "1.2.3"))
        #expect(!AppVersion.isNewer(tag: "v0.9.9", than: "1.0.0"))
    }

    @Test func componentsCompareNumericallyNotAsText() {
        #expect(AppVersion.isNewer(tag: "v1.10.0", than: "1.9.0"))
        #expect(!AppVersion.isNewer(tag: "v1.9.0", than: "1.10.0"))
        #expect(AppVersion.isNewer(tag: "v0.10.0", than: "0.9.9"))
    }

    @Test func invalidTagsAreIgnored() {
        for tag in ["1.2.3", "v1.2", "v1.2.3.4", "v1.2.x", "v 1.2.3", "v1..3", "release-1.2.3"] {
            #expect(!AppVersion.isNewer(tag: tag, than: "1.0.0"), "\(tag)")
            #expect(AppVersion.displayVersion(ofTag: tag) == nil, "\(tag)")
        }
    }

    @Test func invalidInstalledVersionNeverReportsAnUpdate() {
        #expect(!AppVersion.isNewer(tag: "v2.0.0", than: "development"))
        #expect(!AppVersion.isNewer(tag: "v2.0.0", than: "1.2"))
    }

    @Test func displayVersionDropsTheTagPrefix() {
        #expect(AppVersion.displayVersion(ofTag: "v1.2.3") == "1.2.3")
        #expect(AppVersion.displayVersion(ofTag: "v10.0.12") == "10.0.12")
    }
}
