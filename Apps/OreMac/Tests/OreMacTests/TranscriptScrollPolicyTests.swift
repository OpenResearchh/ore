import Testing

@testable import OreMac

struct TranscriptScrollPolicyTests {
    @Test func aFreshTranscriptFollowsTheAgent() {
        let policy = TranscriptScrollPolicy()
        #expect(policy.allowsAutoScroll)
        #expect(policy.allowsBackgroundMeasuring)
    }

    @Test func scrollingAwayStopsTheFollowImmediately() {
        var policy = TranscriptScrollPolicy()
        policy.userDidBeginScroll()
        policy.userDidScroll(atBottom: false)
        #expect(!policy.isFollowingBottom)
        #expect(!policy.allowsAutoScroll)
    }

    @Test func aGestureSuspendsAutoScrollEvenWhileStillAtTheBottom() {
        // Mid-flick the offset can still read as "at the bottom", but scrolling
        // there anyway cancels the reader's momentum.
        var policy = TranscriptScrollPolicy()
        policy.userDidBeginScroll()
        #expect(policy.isFollowingBottom)
        #expect(!policy.allowsAutoScroll)
    }

    @Test func returningToTheBottomResumesFollowing() {
        var policy = TranscriptScrollPolicy()
        policy.userDidBeginScroll()
        policy.userDidScroll(atBottom: false)
        policy.userDidScroll(atBottom: true)
        policy.userDidEndScroll(atBottom: true)
        #expect(policy.allowsAutoScroll)
    }

    @Test func settlingAwayFromTheBottomKeepsTheReaderWhereTheyAre() {
        var policy = TranscriptScrollPolicy()
        policy.userDidBeginScroll()
        policy.userDidEndScroll(atBottom: false)
        #expect(!policy.isUserScrolling)
        #expect(!policy.allowsAutoScroll)
        // The gesture is over, so speculative measuring may run again.
        #expect(policy.allowsBackgroundMeasuring)
    }

    @Test func measuringYieldsWhileAGestureIsInFlight() {
        var policy = TranscriptScrollPolicy()
        policy.userDidBeginScroll()
        #expect(!policy.allowsBackgroundMeasuring)
        policy.userDidEndScroll(atBottom: true)
        #expect(policy.allowsBackgroundMeasuring)
    }

    @Test func jumpingToAnEarlierTurnStopsTheAgentPullingTheViewBack() {
        var policy = TranscriptScrollPolicy()
        policy.didJump(toBottom: false)
        #expect(!policy.allowsAutoScroll)
    }

    @Test func jumpingToTheFootResumesFollowing() {
        var policy = TranscriptScrollPolicy()
        policy.didJump(toBottom: false)
        policy.didJump(toBottom: true)
        #expect(policy.allowsAutoScroll)
    }

    @Test func offscreenRedrawsAreHeldBackOnlyWhenNobodyIsWatchingTheFoot() {
        var policy = TranscriptScrollPolicy()
        // Following at the bottom: the streaming row is on screen, draw it now.
        #expect(!policy.deferOffscreenRedraws)

        policy.userDidBeginScroll()
        #expect(policy.deferOffscreenRedraws)

        policy.userDidEndScroll(atBottom: false)
        // Settled part-way up: the agent is writing somewhere they cannot see.
        #expect(policy.deferOffscreenRedraws)

        policy.userDidBeginScroll()
        policy.userDidEndScroll(atBottom: true)
        #expect(!policy.deferOffscreenRedraws)
    }

    @Test func measuringIsHeldBackOnlyMidGestureAwayFromTheFoot() {
        var policy = TranscriptScrollPolicy()
        // Following: the row is on screen and its height is wanted now.
        #expect(!policy.defersOffscreenHeights)

        policy.userDidBeginScroll()
        // Still reading as "at the bottom" mid-flick: the row is in view.
        #expect(!policy.defersOffscreenHeights)

        policy.userDidScroll(atBottom: false)
        #expect(policy.defersOffscreenHeights)

        policy.userDidEndScroll(atBottom: false)
        // Settled part-way up: nothing is competing with the gesture any more,
        // so the document goes back to being its true length.
        #expect(!policy.defersOffscreenHeights)
        #expect(policy.deferOffscreenRedraws)
    }
}
