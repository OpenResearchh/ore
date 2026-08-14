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

    @Test func locateFindsAKnownSystemBinary() {
        #expect(ShellEnvironment.locate("git") != nil)
        #expect(ShellEnvironment.locate("definitely-not-a-real-binary-xyz") == nil)
    }

    @Test func locateAcceptsAnAbsolutePathUnchanged() {
        #expect(ShellEnvironment.locate("/bin/sh") == "/bin/sh")
        #expect(ShellEnvironment.locate("/bin/definitely-missing") == nil)
    }
}
