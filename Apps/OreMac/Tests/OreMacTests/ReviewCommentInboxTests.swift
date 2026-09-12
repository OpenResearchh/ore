import OreProtocol
import Testing

@testable import OreMac

struct ReviewCommentInboxTests {
    @Test func reviewTabOwnsCommentsNotTheSelectedTab() {
        let review = ChatID(rawValue: "review")
        let selected = ChatID(rawValue: "selected")
        #expect(ReviewCommentInbox.owner(reviewInbox: review, busyChats: [selected]) == review)
    }

    @Test func aBusyChatReceivesFindingsWhenThereIsNoReviewTab() {
        let busy = ChatID(rawValue: "busy")
        #expect(ReviewCommentInbox.owner(reviewInbox: nil, busyChats: [busy]) == busy)
        #expect(ReviewCommentInbox.owner(reviewInbox: nil, busyChats: []) == nil)
    }

    @Test func aCommentAlreadyOnAnotherTabIsNotCopied() {
        let finding = DiffCommentReference(
            filePath: "App.swift", startLine: 1, endLine: 1, body: "fix this"
        )
        #expect(
            ReviewCommentInbox.shouldAttach(
                finding,
                ownerComments: [],
                otherChatsComments: [[finding]]
            ) == false
        )
        #expect(
            ReviewCommentInbox.shouldAttach(
                finding,
                ownerComments: [finding],
                otherChatsComments: []
            ) == false
        )
        #expect(
            ReviewCommentInbox.shouldAttach(
                finding,
                ownerComments: [],
                otherChatsComments: []
            )
        )
    }
}
