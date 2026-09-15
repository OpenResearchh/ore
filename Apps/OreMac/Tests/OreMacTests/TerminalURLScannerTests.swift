import Foundation
import Testing

@testable import OreMac

struct TerminalURLScannerTests {
    private func feed(_ scanner: inout TerminalURLScanner, _ text: String) -> [String] {
        scanner.scan(Array(text.utf8)[...]).map(\.absoluteString)
    }

    @Test func outputWithoutASeparatorFindsNothingAndCarriesOnlyASchemeTail() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, String(repeating: "compiling module\n", count: 400)).isEmpty)
        #expect(scanner.carry.count <= TerminalURLScanner.schemeCarry)
    }

    @Test func findsAnAddressInOneChunk() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "  Local:   http://localhost:5173/\n") == ["http://localhost:5173/"])
    }

    @Test func findsAnAddressCutMidHost() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "ready on http://local").isEmpty)
        #expect(feed(&scanner, "host:3000\n") == ["http://localhost:3000"])
    }

    @Test func findsAnAddressWhoseSeparatorIsCutAcrossChunks() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "listening at http:").isEmpty)
        #expect(feed(&scanner, "//127.0.0.1:8080 ok\n") == ["http://127.0.0.1:8080"])

        var cutLater = TerminalURLScanner()
        #expect(feed(&cutLater, "listening at https:/").isEmpty)
        #expect(feed(&cutLater, "/localhost:8443\n") == ["https://localhost:8443"])
    }

    @Test func findsAnAddressWhoseSchemeIsCutAcrossChunks() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "open htt").isEmpty)
        #expect(feed(&scanner, "ps://localhost:4000\n") == ["https://localhost:4000"])
    }

    @Test func waitsForAPortCutAfterItsColon() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "server: http://localhost:").isEmpty)
        #expect(feed(&scanner, "4321\n") == ["http://localhost:4321"])
    }

    @Test func stripsTrailingPunctuation() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "(see http://localhost:3000/docs).\n") == ["http://localhost:3000/docs"])
    }

    @Test func ignoresRemoteAddresses() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "fetching https://example.com/pkg.tgz\n").isEmpty)
    }

    @Test func reportsAnAddressOnlyOnce() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "http://localhost:3000\n") == ["http://localhost:3000"])
        #expect(feed(&scanner, "GET / 200\n").isEmpty)
        #expect(feed(&scanner, "GET /favicon.ico 404\n").isEmpty)
    }

    @Test func carryStaysSmallAfterAFarAwaySeparator() {
        var scanner = TerminalURLScanner()
        let chunk = "fetching https://example.com " + String(repeating: "a", count: 5000)
        #expect(feed(&scanner, chunk).isEmpty)
        #expect(scanner.carry.count <= TerminalURLScanner.schemeCarry)
    }

    @Test func findsEveryAddressInALargeChunk() {
        var scanner = TerminalURLScanner()
        let noise = String(repeating: "x", count: 8000)
        let chunk = "api http://localhost:8000\n\(noise)\nweb http://localhost:5173\n"
        #expect(feed(&scanner, chunk) == ["http://localhost:8000", "http://localhost:5173"])
    }

    @Test func separatorSearchReportsTheFirstOffset() {
        let bytes = Array("a:b://c://".utf8)[...]
        #expect(TerminalURLScanner.firstSeparator(in: bytes) == 3)
        #expect(TerminalURLScanner.firstSeparator(in: Array("a:/b:".utf8)[...]) == nil)
    }

    @Test func findsAnAddressFedOneByteAtATime() {
        // The worst boundary case there is: every byte its own chunk. If the
        // carry rules are right anywhere, they are right here.
        var scanner = TerminalURLScanner()
        var found: [String] = []
        for byte in Array("vite ready http://localhost:5173/app x\n".utf8) {
            found += scanner.scan([byte][...]).map(\.absoluteString)
        }
        #expect(found == ["http://localhost:5173/app"])
    }

    @Test func findsTheOtherLoopbackSpellings() {
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "on http://[::1]:9000/ and http://0.0.0.0:8080 done\n")
            == ["http://[::1]:9000/", "http://0.0.0.0:8080"])
    }

    @Test func survivesEscapeSequencesAndInvalidUTF8() {
        // A PTY chunk is bytes, not text: colour codes, and a multi-byte
        // character the previous chunk cut in half.
        var scanner = TerminalURLScanner()
        var bytes = Array("\u{1B}[32m ok \u{1B}[0m ".utf8)
        bytes += [0xFF, 0xFE, 0x80]
        bytes += Array("http://localhost:7000\n".utf8)
        #expect(scanner.scan(bytes[...]).map(\.absoluteString) == ["http://localhost:7000"])
    }

    @Test func aStreamOfOpenCandidatesKeepsTheCarryBounded() {
        // "postgres://" never completes an address, so the carry keeps being
        // handed forward; it must not become the session's output.
        var scanner = TerminalURLScanner()
        for _ in 0..<200 { #expect(feed(&scanner, "postgres://").isEmpty) }
        #expect(scanner.carry.count <= TerminalURLScanner.carryLimit)
    }

    @Test func findsAnAddressCutAfterAnEarlierOneResolved() {
        // The second address starts before the point the first one resolved to,
        // so the carry has to reach back past it.
        var scanner = TerminalURLScanner()
        #expect(feed(&scanner, "first http://localhost:1/x then htt") == ["http://localhost:1/x"])
        #expect(feed(&scanner, "p://localhost:2/y z\n") == ["http://localhost:2/y"])
    }

    @Test func spanningSeparatorIsDetectedFromEitherSide() {
        #expect(TerminalURLScanner.separatorSpans(Array("http:".utf8), Array("//x".utf8)[...]))
        #expect(TerminalURLScanner.separatorSpans(Array("http:/".utf8), Array("/x".utf8)[...]))
        #expect(!TerminalURLScanner.separatorSpans(Array("http:".utf8), Array("/x".utf8)[...]))
        #expect(!TerminalURLScanner.separatorSpans(Array("http".utf8), Array("://".utf8)[...]))
    }
}
