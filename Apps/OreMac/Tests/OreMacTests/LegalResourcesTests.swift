import Foundation
import Testing

@testable import OreMac

/// ORE ships other people's work, and their licenses ask for their notices to
/// travel with it. These keep the in-app copies honest: a new dependency, or an
/// edited LICENSE or NOTICE, fails here until the legal resources are
/// regenerated (Scripts/generate-legal-resources.sh).
@MainActor
struct LegalResourcesTests {
    /// Apps/OreMac, from Apps/OreMac/Tests/OreMacTests/<this file>.
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let repoRoot = appRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct Resolved: Decodable {
        struct Pin: Decodable { let identity: String }
        let pins: [Pin]
    }

    @Test func everyPinnedPackageIsAcknowledged() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("Package.resolved"))
        let pinned = Set(try JSONDecoder().decode(Resolved.self, from: data).pins.map(\.identity))
        let acknowledged = Set(ThirdPartyComponent.all.compactMap(\.packageIdentity))
        #expect(pinned == acknowledged)
    }

    @Test func theAppCarriesEveryLicenseInFull() throws {
        let text = try #require(LegalDocument.thirdPartyLicenses.text)
        for component in ThirdPartyComponent.all {
            #expect(text.contains(component.name), "\(component.name) has no license section")
        }
        #expect(text.contains("Permission is hereby granted"), "MIT texts are verbatim, not summarised")
        #expect(text.contains("creativecommons.org/licenses/by/4.0"))
    }

    @Test func theBundledLicenseAndNoticeMatchTheRepository() throws {
        let license = try String(contentsOf: Self.repoRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        let notice = try String(contentsOf: Self.repoRoot.appendingPathComponent("NOTICE"), encoding: .utf8)
        #expect(LegalDocument.license.text == license)
        #expect(LegalDocument.notice.text == notice)
    }

    @Test func noticeNamesEveryComponentTheAppCredits() throws {
        let notice = try String(contentsOf: Self.repoRoot.appendingPathComponent("NOTICE"), encoding: .utf8)
        for component in ThirdPartyComponent.all {
            #expect(notice.contains(component.name), "NOTICE doesn't mention \(component.name)")
        }
        #expect(notice.contains(OreAbout.company))
    }
}
