import Foundation
import Testing

@testable import OreHarness
@testable import OreSupport
@testable import OreProtocol

struct ShellEnvironmentTests {
    @Test func providerCredentialsAreScrubbedByDefault() {
        // A key in the developer's shell profile must never reach the agent
        // CLI: the CLI would silently bill the API account instead of using
        // the subscription the user is paying for.
        let environment = ShellEnvironment.childEnvironment(
            overrides: ["ANTHROPIC_API_KEY": "sk-should-not-survive"],
            allowProviderCredentials: false
        )
        #expect(environment["ANTHROPIC_API_KEY"] == nil)

        for key in ShellEnvironment.providerCredentialKeys {
            #expect(environment[key] == nil, "\(key) leaked into the child environment")
        }
    }

    @Test func overridesSurviveWhenAPIKeysAreExplicitlyAllowed() {
        let environment = ShellEnvironment.childEnvironment(
            overrides: ["ANTHROPIC_API_KEY": "sk-explicit"],
            allowProviderCredentials: true
        )
        #expect(environment["ANTHROPIC_API_KEY"] == "sk-explicit")
    }

    @Test func nonCredentialOverridesAreAlwaysApplied() {
        let environment = ShellEnvironment.childEnvironment(overrides: ["ORE_WORKSPACE": "belgrade"])
        #expect(environment["ORE_WORKSPACE"] == "belgrade")
    }

    @Test func loginShellProvidesAUsablePath() {
        // The whole point of the probe: a GUI-launched app inherits a PATH
        // without homebrew or any version manager on it.
        let environment = ShellEnvironment.loginShellEnvironment()
        let path = try? #require(environment["PATH"])
        #expect(path?.isEmpty == false)
    }

    @Test func concurrentCallersShareOneComputedValue() {
        // Every harness launch and git call asks for the environment; the
        // probe must still run once, and everyone must get its result.
        let cache = ShellEnvironment.Cache()
        let computeCount = Lockbox(0)
        let results = Lockbox<[[String: String]]>([])

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let value = cache.resolve {
                let count = computeCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                Thread.sleep(forTimeInterval: 0.05)
                return ["PROBE": "\(count)"]
            }
            results.withLock { $0.append(value) }
        }

        #expect(computeCount.get() == 1)
        #expect(results.get().count == 16)
        #expect(results.get().allSatisfy { $0 == ["PROBE": "1"] })
    }

    @Test func theCacheLockIsNotHeldWhileComputing() {
        // Invalidating mid-probe used to block behind the probe itself.
        let cache = ShellEnvironment.Cache()
        let computing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = Lockbox<[String: String]>([:])
        let firstDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            first.set(cache.resolve {
                computing.signal()
                release.wait()
                return ["PROBE": "stale"]
            })
            firstDone.signal()
        }
        computing.wait()
        cache.invalidate()  // Would deadlock if the lock were held.
        release.signal()
        firstDone.wait()

        #expect(first.get() == ["PROBE": "stale"])
        // The reading raced an invalidation, so it isn't kept.
        #expect(cache.resolve { ["PROBE": "fresh"] } == ["PROBE": "fresh"])
        #expect(cache.resolve { ["PROBE": "again"] } == ["PROBE": "fresh"])
    }

    @Test func locateFindsAKnownSystemBinary() {
        #expect(ShellEnvironment.locate("git") != nil)
        #expect(ShellEnvironment.locate("definitely-not-a-real-binary-xyz") == nil)
    }

    @Test func locateAcceptsAnAbsolutePathUnchanged() {
        #expect(ShellEnvironment.locate("/bin/sh") == "/bin/sh")
        #expect(ShellEnvironment.locate("/bin/definitely-missing") == nil)
    }
}
