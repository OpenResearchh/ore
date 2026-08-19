import Testing

@testable import OreMac

/// The transcript repair pass: rewrite near-misses toward known workspace and
/// repository names, and absolutely nothing else.
struct VoiceVocabularyTests {
    private let vocabulary = VoiceVocabulary(names: [
        "metcalfe", "kailash", "Book of Optics", "hideki-yukawa",
    ])

    @Test func nearMissesBecomeTheKnownName() {
        #expect(
            vocabulary.corrected("what's happening in metcalf right now")
                == "what's happening in metcalfe right now"
        )
        #expect(
            vocabulary.corrected("open kailish for me")
                == "open kailash for me"
        )
    }

    @Test func multiWordNamesMatchAcrossTheirWords() {
        #expect(
            vocabulary.corrected("what did book of optic do yesterday")
                == "what did Book of Optics do yesterday"
        )
    }

    @Test func punctuationSurvivesTheRewrite() {
        #expect(
            vocabulary.corrected("push metcalf, then archive it")
                == "push metcalfe, then archive it"
        )
    }

    @Test func ordinaryWordsAreLeftAlone() {
        // "medical" is 4 edits from "metcalfe"; "know" starts with the wrong
        // letter for every name. Neither may be rewritten.
        let sentence = "I know the medical project needs review"
        #expect(vocabulary.corrected(sentence) == sentence)
    }

    @Test func exactNamesAndOtherNamesAreNeverRewritten() {
        // Already right → untouched; and one known name must never morph
        // into another, however close.
        #expect(
            vocabulary.corrected("show me metcalfe please")
                == "show me metcalfe please"
        )
        let twoNames = VoiceVocabulary(names: ["parser", "parsers"])
        #expect(twoNames.corrected("check parsers now") == "check parsers now")
    }

    @Test func shortNamesGetNoFuzzAtAll() {
        let short = VoiceVocabulary(names: ["core"])
        #expect(short.corrected("the care package") == "the care package")
    }
}
