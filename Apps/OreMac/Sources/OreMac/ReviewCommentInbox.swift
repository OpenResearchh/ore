import OreProtocol

/// Review comments are posted against the workspace, but the composer chips
/// that carry them belong to one tab — the Review chat that produced them,
/// or the busy chat that is still posting. They must not follow whichever
/// tab happens to be selected.
enum ReviewCommentInbox {
    static func owner(reviewInbox: ChatID?, busyChats: [ChatID]) -> ChatID? {
        if let reviewInbox { return reviewInbox }
        return busyChats.last
    }

    /// A comment already sitting on another tab stays there. The inbox only
    /// receives findings that have not been claimed yet.
    static func shouldAttach(
        _ comment: DiffCommentReference,
        ownerComments: [DiffCommentReference],
        otherChatsComments: [[DiffCommentReference]]
    ) -> Bool {
        if ownerComments.contains(comment) { return false }
        return !otherChatsComments.contains { $0.contains(comment) }
    }
}
