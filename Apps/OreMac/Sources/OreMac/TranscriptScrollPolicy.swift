import Foundation

/// Decides when the transcript is allowed to move itself.
///
/// A transcript being written to while the reader scrolls has two callers
/// competing for one scroll offset: the agent, which wants its newest text in
/// view, and the reader, who wants the line they are on to stay where they put
/// it. The reader wins whenever the two disagree — being pulled back to the
/// bottom mid-sentence is worse than missing the newest token for a moment.
///
/// Kept apart from the table so the rule is stated once and can be tested
/// without a window: the geometry lives in the coordinator, the intent here.
struct TranscriptScrollPolicy {
    /// Whether new output should pull the view to the bottom.
    private(set) var isFollowingBottom = true

    /// Whether a gesture — or the momentum it threw — is driving the scroll.
    private(set) var isUserScrolling = false

    /// The reader took hold of the view. Nothing may move it until they let go,
    /// following or not: a programmatic scroll landing mid-flick cancels the
    /// momentum, which is what makes a fast scroll feel like it is being fought.
    mutating func userDidBeginScroll() {
        isUserScrolling = true
    }

    /// The offset moved under the reader's hand. Read live, so scrolling away
    /// stops the follow at once rather than at the end of a long flick.
    mutating func userDidScroll(atBottom: Bool) {
        isFollowingBottom = atBottom
    }

    /// The gesture and its momentum have settled. Following resumes only if the
    /// reader left the view at the bottom — that is the gesture that means
    /// "keep up with the agent again".
    mutating func userDidEndScroll(atBottom: Bool) {
        isUserScrolling = false
        isFollowingBottom = atBottom
    }

    /// A jump the app made on the reader's behalf — restoring a chat's saved
    /// offset, or the turn rail. It decides the follow state outright: landing
    /// on an old turn means stop following, landing at the foot means resume.
    mutating func didJump(toBottom atBottom: Bool) {
        isFollowingBottom = atBottom
    }

    /// New content pins to the bottom only when the reader is not holding the
    /// view somewhere else.
    var allowsAutoScroll: Bool { isFollowingBottom && !isUserScrolling }

    /// Speculative measuring waits for the gesture to end. It is the work most
    /// likely to be felt as a stutter and the least urgent to finish.
    var allowsBackgroundMeasuring: Bool { !isUserScrolling }

    /// Redrawing a row the reader cannot see is pure cost while text streams.
    /// The row still has its height corrected; only the draw is held back until
    /// the view settles, which is also when the reader could first notice it.
    var deferOffscreenRedraws: Bool { isUserScrolling || !isFollowingBottom }

    /// Stronger than `deferOffscreenRedraws`, and only while a gesture is
    /// actually in flight somewhere other than the foot: even *measuring* a row
    /// below the viewport is held back. Measuring means laying the row's text
    /// out with TextKit, and a long streaming reply re-measured ten times a
    /// second is the one piece of transcript work big enough to be felt between
    /// the frames of a flick. The document is briefly the wrong length — the
    /// knob lags — which is the trade: correct length, or a smooth gesture.
    var defersOffscreenHeights: Bool { isUserScrolling && !isFollowingBottom }
}
