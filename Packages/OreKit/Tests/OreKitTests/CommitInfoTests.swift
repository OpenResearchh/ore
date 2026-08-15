import Foundation
import Testing

@testable import OreGit

struct CommitInfoTests {
    @Test func parseLogReadsFieldsAndShortstat() {
        let raw = """
        abcdef0123456789abcdef0123456789abcdef01\u{1f}abcdef0\u{1f}ORE Workbench UI Polish\u{1f}Tushar Ojha\u{1f}2026-08-15T12:00:00Z
         3 files changed, 42 insertions(+), 7 deletions(-)
        1111111111111111111111111111111111111111\u{1f}1111111\u{1f}Follow-up\u{1f}Tushar Ojha\u{1f}2026-08-15T12:01:00Z
         1 file changed, 1 insertion(+)
        """
        let commits = CommitInfo.parseLog(raw)
        #expect(commits.count == 2)
        #expect(commits[0].shortSHA == "abcdef0")
        #expect(commits[0].subject == "ORE Workbench UI Polish")
        #expect(commits[0].author == "Tushar Ojha")
        #expect(commits[0].filesChanged == 3)
        #expect(commits[0].insertions == 42)
        #expect(commits[0].deletions == 7)
        #expect(commits[1].insertions == 1)
        #expect(commits[1].deletions == 0)
        #expect(commits[1].filesChanged == 1)
    }

    @Test func parseShortstatHandlesSingularAndMissingSides() {
        let both = CommitInfo.parseShortstat(" 2 files changed, 10 insertions(+), 3 deletions(-)")
        #expect(both?.files == 2)
        #expect(both?.insertions == 10)
        #expect(both?.deletions == 3)
        let plusOnly = CommitInfo.parseShortstat("1 file changed, 1 insertion(+)")
        #expect(plusOnly?.files == 1)
        #expect(plusOnly?.insertions == 1)
        #expect(plusOnly?.deletions == 0)
        let minusOnly = CommitInfo.parseShortstat("1 file changed, 4 deletions(-)")
        #expect(minusOnly?.deletions == 4)
        #expect(minusOnly?.insertions == 0)
    }
}
