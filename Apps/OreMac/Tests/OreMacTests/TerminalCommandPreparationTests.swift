import Foundation
import Testing

@testable import OreMac

struct TerminalCommandPreparationTests {
    @Test func bracketedPasteStagesEveryLineWithoutPressingReturn() {
        let script = "first\nsecond"
        let pasted = TerminalRegistry.bracketedPaste(script)

        #expect(pasted == "\u{1B}[200~first\nsecond\u{1B}[201~")
        #expect(!pasted.hasSuffix("\n"))
    }

    @Test func trackedCommandReportsTheCommandsExitWithoutClosingTheShell() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let prepared = TerminalRegistry.trackedCommand("first\nsecond", operationID: id)

        #expect(prepared.hasPrefix("first\nsecond\n__ore_command_status=$?"))
        #expect(prepared.contains("OreCommand=11111111-2222-3333-4444-555555555555"))
        #expect(prepared.contains("Exit=%d"))
        #expect(!prepared.contains("exit "), "the login shell must remain alive")
    }

    @Test func completionMarkerSurvivesPTYChunkBoundaries() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let marker = "noise\u{1B}]1337;OreCommand=\(id.uuidString);Exit=0\u{7}prompt"
        let bytes = Array(marker.utf8)
        var scanner = TerminalCommandCompletionScanner()

        #expect(scanner.scan(bytes[..<18]).isEmpty)
        #expect(scanner.scan(bytes[18..<43]).isEmpty)
        #expect(scanner.scan(bytes[43...]) == [
            TerminalCommandCompletion(id: id, exitCode: 0),
        ])
    }

    @Test func completionMarkerCarriesFailureStatus() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let marker = "\u{1B}]1337;OreCommand=\(id.uuidString);Exit=17\u{7}"
        var scanner = TerminalCommandCompletionScanner()

        #expect(scanner.scan(Array(marker.utf8)[...]) == [
            TerminalCommandCompletion(id: id, exitCode: 17),
        ])
    }
}
