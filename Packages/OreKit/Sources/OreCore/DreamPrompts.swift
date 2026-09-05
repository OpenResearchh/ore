import Foundation
import OreProtocol

/// Prompt contract for a dream task. "No finding posted" means the dream
/// produced nothing worth the user's morning; max three findings per task.
public enum DreamPrompts {
    public static func opening(kind: DreamKind, repositoryName: String, why: String) -> String {
        let shared = """
        You are ORE Dream Mode, running unattended overnight research on the \
        project "\(repositoryName)". The user is asleep. You will not get a reply.

        Why this dream ran: \(why)

        This session is read-only research. Do not edit files. Do not commit. \
        Do not push. Do not open PRs. Do not run the test suite. Do not install \
        packages. Do not use secrets or `.env` files.

        When you find something worth the user's morning, call the MCP tool \
        PostDreamFinding. Post at most 3 findings. If you have nothing solid, \
        post nothing — an empty dream is better than noise.

        Each finding needs:
        - title: one short sentence
        - summary: markdown, a paragraph or two, with enough context to act
        - confidence: 0–1 (be honest; 0.5 is "maybe")
        - severity: info | warning | error
        - evidence: file paths and line numbers when you have them

        Do not append a narration tag. End by listing how many findings you posted.
        """

        let focus: String
        switch kind {
        case .review:
            focus = """
            Kind: code review.
            Read recent diffs versus the default branch, then the modules they \
            touch. Look for bugs, race conditions, missing error handling, \
            unsafe unwraps, and cleanups that would actually matter. Skip nits.
            """
        case .bugHunt:
            focus = """
            Kind: adversarial bug hunt.
            Try to break the app from the code. Hunt for logic errors, \
            authorization holes, off-by-ones, and silent failures. A finding \
            without a plausible repro path is not a finding.
            """
        case .dependencyAudit:
            focus = """
            Kind: dependency audit.
            Check manifests and lockfiles for updates, CVEs, deprecations, and \
            license drift. Fact-check imports and URLs against the web when you \
            can. Do not bump anything — report only.
            """
        case .featureIdeas:
            focus = """
            Kind: what should be built next.
            Ground every idea in the code and recent activity. No generic \
            product advice.
            """
        case .testRun, .fix, .appExplore:
            focus = """
            This kind is not enabled for unattended runs. Stay in research: \
            report what you would have done, then stop.
            """
        }

        return shared + "\n\n" + focus
    }

    public static func continuation(reason: String) -> String {
        """
        The unattended session was paused (\(reason)). Continue the same \
        research from where you left off. Do not start over. Do not edit, \
        commit, push, or install anything.

        When you have something worth the morning, call PostDreamFinding. \
        At most 3 findings total for this dream. If nothing is solid, post \
        nothing and stop.
        """
    }

    public static func acceptedFindingPrompt(_ finding: DreamFindingSummary) -> String {
        var lines = [
            "Work on this finding from last night's Dream Mode research.",
            "",
            finding.title,
            "",
            finding.summary,
        ]
        if !finding.evidence.isEmpty {
            lines.append("")
            lines.append("Evidence:")
            for item in finding.evidence {
                var entry = "-"
                if let path = item.path {
                    entry += " \(item.line.map { "\(path):\($0)" } ?? path)"
                }
                if let note = item.note, !note.isEmpty {
                    entry += " — \(note)"
                }
                lines.append(entry)
            }
        }
        if !finding.why.isEmpty {
            lines.append("")
            lines.append("Why the dream ran: \(finding.why)")
        }
        return lines.joined(separator: "\n")
    }
}
