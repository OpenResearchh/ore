import Foundation
import Testing

@testable import OreCore
@testable import OreProtocol

struct ChatChromePublishPolicyTests {
    @Test func theFirstUsageReportAlwaysPublishes() {
        #expect(ChatChromePublishPolicy.shouldPublishUsage(
            previous: nil,
            next: UsageReport(inputTokens: 1, outputTokens: 1, contextWindow: 200_000)
        ))
    }

    @Test func subPercentTokenTicksStayOffTheChromeStream() {
        let window = 200_000
        let previous = UsageReport(inputTokens: 100, outputTokens: 10, contextWindow: window)
        let next = UsageReport(inputTokens: 100, outputTokens: 50, contextWindow: window)
        #expect(!ChatChromePublishPolicy.shouldPublishUsage(previous: previous, next: next))
    }

    @Test func aVisibleContextPercentChangePublishes() {
        let window = 100
        let previous = UsageReport(inputTokens: 10, outputTokens: 0, contextWindow: window)
        let next = UsageReport(inputTokens: 10, outputTokens: 5, contextWindow: window)
        #expect(ChatChromePublishPolicy.shouldPublishUsage(previous: previous, next: next))
    }
}
