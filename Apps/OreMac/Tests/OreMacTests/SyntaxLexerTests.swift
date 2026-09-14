import AppKit
import Testing

@testable import OreMac

/// The lexer is judged by what a reader sees, so these assert on the capture
/// a token ends up with rather than on the token stream's shape.
@MainActor
struct SyntaxLexerTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// The capture at the start of the `occurrence`th `token` in `code`, or nil
    /// when it is left uncoloured. Later tokens win, as they do when painted.
    private func capture(
        of token: String, in code: String, language: String?, occurrence: Int = 1
    ) -> String? {
        let tokens = SyntaxLexer.tokens(for: code, language: SyntaxHighlighter.canonicalName(language))
        let text = code as NSString
        var searchFrom = 0
        var location = NSNotFound
        for _ in 0..<occurrence {
            let range = text.range(of: token, range: NSRange(location: searchFrom, length: text.length - searchFrom))
            guard range.location != NSNotFound else { return "<missing>" }
            location = range.location
            searchFrom = range.location + range.length
        }
        return tokens.last { $0.start <= location && location < $0.end }?.kind.capture
    }

    private func color(of token: String, in code: String, language: String?) -> NSColor? {
        let result = SyntaxHighlighter.shared.highlight(code, language: language, font: font, cache: false)
        let location = (code as NSString).range(of: token).location
        return result.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    // MARK: - Precedence

    @Test func slashesAndHashesInsideStringsAreNotComments() {
        let js = #"const url = "https://example.com/#top"; // trailing"#
        #expect(capture(of: "example", in: js, language: "js") == "string")
        #expect(capture(of: "top", in: js, language: "js") == "string")
        #expect(capture(of: "trailing", in: js, language: "js") == "comment")

        let python = ##"label = "# not a comment"  # real comment"##
        #expect(capture(of: "not", in: python, language: "python") == "string")
        #expect(capture(of: "real", in: python, language: "python") == "comment")
    }

    @Test func quotesInsideCommentsAreNotStrings() {
        let code = "// it's \"quoted\"\nlet x = 1;"
        #expect(capture(of: "quoted", in: code, language: "rust") == "comment")
        #expect(capture(of: "let", in: code, language: "rust") == "keyword")
        #expect(capture(of: "1", in: code, language: "rust") == "number")
    }

    @Test func keywordsBelongToTheirLanguage() {
        #expect(capture(of: "def", in: "def greet(name):", language: "python") == "keyword")
        #expect(capture(of: "greet", in: "def greet(name):", language: "python") == "function")
        #expect(capture(of: "def", in: "def := 1", language: "go") == nil)
        #expect(capture(of: "func", in: "func main() {}", language: "go") == "keyword")
        #expect(capture(of: "fn", in: "fn main() {}", language: "go") == nil)
    }

    @Test func nestedBlockCommentsNestOnlyWhereTheLanguageAllows() {
        let code = "/* outer /* inner */ still */ fn"
        #expect(capture(of: "still", in: code, language: "rust") == "comment")
        #expect(capture(of: "fn", in: code, language: "rust") == "keyword")
        #expect(capture(of: "still", in: code, language: "c") == nil)
        #expect(capture(of: "{- a {- b -} c -}", in: "{- a {- b -} c -} main", language: "haskell") == "comment")
    }

    // MARK: - Strings

    @Test func pythonTripleQuotedStringsSpanLines() {
        let code = "\"\"\"Doc\n# not a comment\n\"\"\"\nvalue = f\"hi {name}\""
        #expect(capture(of: "not", in: code, language: "python") == "string")
        #expect(capture(of: "value", in: code, language: "python") == nil)
        #expect(capture(of: "hi", in: code, language: "python") == "string")
        // An f-string's replacement field is code, not string.
        #expect(capture(of: "name", in: code, language: "python") == nil)
        #expect(capture(of: "'''x'''", in: "a = '''x'''", language: "python") == "string")
    }

    @Test func rustRawStringsLifetimesAndCharacters() {
        let code = ##"let s = r#"a "quoted" // not"#; fn f<'a>(c: char) { let x = 'y'; }"##
        #expect(capture(of: "quoted", in: code, language: "rs") == "string")
        #expect(capture(of: "not", in: code, language: "rs") == "string")
        #expect(capture(of: "fn", in: code, language: "rs") == "keyword")
        #expect(capture(of: "'a", in: code, language: "rs") == "label")
        #expect(capture(of: "'y'", in: code, language: "rs") == "string")
        #expect(capture(of: "#[derive", in: "#[derive(Debug)]\nstruct A;", language: "rust") == "attribute")
    }

    @Test func escapesAndInterpolationAreDistinguished() {
        let js = "`total: ${count + 1}\\n`"
        #expect(capture(of: "total", in: js, language: "javascript") == "string")
        #expect(capture(of: "${", in: js, language: "javascript") == "punctuation.special")
        #expect(capture(of: "1", in: js, language: "javascript") == "number")
        #expect(capture(of: "\\n", in: js, language: "javascript") == "string.escape")

        let swift = #"print("value: \(x)")"#
        #expect(capture(of: "value", in: swift, language: "swift") == "string")
        #expect(capture(of: "x)", in: swift, language: "swift") == nil)
    }

    @Test func anUnterminatedApostropheDoesNotPaintTheLine() {
        #expect(capture(of: "stop", in: "don't stop now", language: nil) == nil)
    }

    // MARK: - Words

    @Test func sqlKeywordsAreCaseInsensitive() {
        let code = "SELECT id FROM users where name = 'it''s' -- note"
        #expect(capture(of: "SELECT", in: code, language: "sql") == "keyword")
        #expect(capture(of: "where", in: code, language: "sql") == "keyword")
        #expect(capture(of: "s'", in: code, language: "sql") == "string")
        #expect(capture(of: "note", in: code, language: "sql") == "comment")
        #expect(capture(of: "id", in: code, language: "sql") == nil)
    }

    @Test func decoratorsTypesAndConstants() {
        let code = "@dataclass\nclass Point(Base):\n    MAX_SIZE = None\n    def area(self): return len(self.x)"
        #expect(capture(of: "@dataclass", in: code, language: "py") == "attribute")
        #expect(capture(of: "Point", in: code, language: "py") == "type")
        #expect(capture(of: "Base", in: code, language: "py") == "type")
        #expect(capture(of: "MAX_SIZE", in: code, language: "py") == "constant")
        #expect(capture(of: "None", in: code, language: "py") == "constant.builtin")
        #expect(capture(of: "self", in: code, language: "py") == "variable.builtin")
        #expect(capture(of: "len", in: code, language: "py") == "function.builtin")
    }

    @Test func shellVariablesCommentsAndAssignments() {
        let code = "FOO=bar\necho \"$HOME and ${USER}\" # done\nx=a#b\ncat <<EOF\n$not code\nEOF\nls"
        #expect(capture(of: "FOO", in: code, language: "bash") == "variable.special")
        #expect(capture(of: "echo", in: code, language: "bash") == "function.builtin")
        #expect(capture(of: "$HOME", in: code, language: "bash") == "variable.special")
        #expect(capture(of: "${USER}", in: code, language: "bash") == "variable.special")
        #expect(capture(of: "and", in: code, language: "bash") == "string")
        #expect(capture(of: "done", in: code, language: "bash") == "comment")
        #expect(capture(of: "#b", in: code, language: "bash") == nil)
        #expect(capture(of: "code", in: code, language: "bash") == "string")
        #expect(capture(of: "ls", in: code, language: "bash") == nil)
    }

    // MARK: - Special lexers

    @Test func htmlTagsAttributesValuesAndDelegatedScript() {
        let code = """
        <!DOCTYPE html>
        <!-- a "comment" -->
        <div class="box">&amp;<script type="module">const x = "</div>";</script>
        <style>p { color: red; }</style></div>
        """
        #expect(capture(of: "DOCTYPE", in: code, language: "html") == "keyword")
        #expect(capture(of: "comment", in: code, language: "html") == "comment")
        #expect(capture(of: "div", in: code, language: "html") == "tag")
        #expect(capture(of: "class", in: code, language: "html") == "attribute")
        #expect(capture(of: "\"box\"", in: code, language: "html") == "string")
        #expect(capture(of: "&amp;", in: code, language: "html") == "string.escape")
        #expect(capture(of: "const", in: code, language: "html") == "keyword")
        #expect(capture(of: "color", in: code, language: "html") == "property")
        #expect(capture(of: "red", in: code, language: "html") == "constant")
        #expect(capture(of: "svg", in: "<svg viewBox=\"0 0 1 1\"/>", language: "svg") == "tag")
    }

    @Test func cssSeparatesSelectorsPropertiesAndValues() {
        let code = "a:hover, .card #id { color: red; margin: 10px !important; background: #fff url(x.png); }"
        #expect(capture(of: "a", in: code, language: "css") == "tag")
        #expect(capture(of: ":hover", in: code, language: "css") == "attribute")
        #expect(capture(of: ".card", in: code, language: "css") == "type")
        #expect(capture(of: "color", in: code, language: "css") == "property")
        #expect(capture(of: "red", in: code, language: "css") == "constant")
        #expect(capture(of: "10px", in: code, language: "css") == "number")
        #expect(capture(of: "!important", in: code, language: "css") == "keyword")
        #expect(capture(of: "#fff", in: code, language: "css") == "number")
        #expect(capture(of: "url", in: code, language: "css") == "function")

        let scss = "$gap: 4px;\n.a { &:hover { padding: $gap; } // note\n}"
        #expect(capture(of: "$gap", in: scss, language: "scss") == "variable.special")
        #expect(capture(of: "padding", in: scss, language: "scss") == "property")
        #expect(capture(of: "note", in: scss, language: "scss") == "comment")
    }

    @Test func yamlKeysValuesAndBlockScalars() {
        let code = """
        name: ore
        count: 3
        enabled: true
        url: http://example.com # note
        list:
          - item: &anchor "quoted"
        script: |
          echo: not a key
        after: *anchor
        """
        #expect(capture(of: "name", in: code, language: "yml") == "property")
        #expect(capture(of: "ore", in: code, language: "yml") == "string")
        #expect(capture(of: "3", in: code, language: "yml") == "number")
        #expect(capture(of: "true", in: code, language: "yml") == "constant.builtin")
        #expect(capture(of: "http", in: code, language: "yml") == "string")
        #expect(capture(of: "note", in: code, language: "yml") == "comment")
        #expect(capture(of: "item", in: code, language: "yml") == "property")
        #expect(capture(of: "&anchor", in: code, language: "yml") == "label")
        #expect(capture(of: "echo", in: code, language: "yml") == "string")
        #expect(capture(of: "after", in: code, language: "yml") == "property")
    }

    @Test func markdownHeadingsInlineStylesAndFences() {
        let code = """
        # Title

        Some *emphasis*, **strong**, `code` and [a link](https://x.dev).
        - item
        ```python
        def run(): pass
        ```
        """
        #expect(capture(of: "Title", in: code, language: "md") == "markup.heading")
        #expect(capture(of: "emphasis", in: code, language: "md") == "markup.italic")
        #expect(capture(of: "strong", in: code, language: "md") == "markup.bold")
        #expect(capture(of: "code", in: code, language: "md") == "markup.raw")
        #expect(capture(of: "a link", in: code, language: "md") == "markup.link")
        #expect(capture(of: "https", in: code, language: "md") == "markup.link.url")
        #expect(capture(of: "- ", in: code, language: "md") == "punctuation.special")
        #expect(capture(of: "def", in: code, language: "md") == "keyword")

        let heading = SyntaxHighlighter.shared.highlight(code, language: "markdown", font: font, cache: false)
        let headingFont = heading.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func configurationFormats() {
        let toml = "[package]\nname = \"ore\" # c\nversion.major = 1\n[[bin]]\narray = [1, 2]"
        #expect(capture(of: "[package]", in: toml, language: "toml") == "type")
        #expect(capture(of: "name", in: toml, language: "toml") == "property")
        #expect(capture(of: "version.major", in: toml, language: "toml") == "property")
        #expect(capture(of: "[[bin]]", in: toml, language: "toml") == "type")
        #expect(capture(of: "c", in: toml, language: "toml", occurrence: 2) == "comment")

        let ini = "; comment\n[core]\neditor = vim"
        #expect(capture(of: "comment", in: ini, language: "ini") == "comment")
        #expect(capture(of: "editor", in: ini, language: "ini") == "property")

        let env = "export API_KEY=\"secret\" # c\nURL=${HOST}/x"
        #expect(capture(of: "API_KEY", in: env, language: "dotenv") == "property")
        #expect(capture(of: "${HOST}", in: env, language: "dotenv") == "variable.special")

        let json5 = "{ key: 'v', \"quoted\": 1 } // c"
        #expect(capture(of: "key", in: json5, language: "json5") == "property")
        #expect(capture(of: "\"quoted\"", in: json5, language: "json5") == "property")
        #expect(capture(of: "'v'", in: json5, language: "json5") == "string")
    }

    @Test func diffLinesAndHunks() {
        let code = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@ func\n-old\n+new\n context"
        #expect(capture(of: "diff --git", in: code, language: "diff") == "diff.header")
        #expect(capture(of: "--- a", in: code, language: "diff") == "diff.header")
        #expect(capture(of: "@@ -1", in: code, language: "diff") == "diff.hunk")
        #expect(capture(of: "old", in: code, language: "diff") == "diff.minus")
        #expect(capture(of: "new", in: code, language: "diff") == "diff.plus")
        #expect(capture(of: "context", in: code, language: "diff") == nil)
    }

    @Test func jsxTagsInTSX() {
        let code = "const App = () => <Button kind=\"primary\" onClick={() => go(1)}>Hi</Button>;"
        #expect(capture(of: "Button", in: code, language: "tsx") == "type")
        #expect(capture(of: "kind", in: code, language: "tsx") == "attribute")
        #expect(capture(of: "go", in: code, language: "tsx") == "function")
        #expect(capture(of: "a < b", in: "if (a < b) {}", language: "tsx") == nil)
    }

    // MARK: - Names

    @Test func wellKnownFileNamesResolve() {
        #expect(SyntaxHighlighter.language(forPath: "Dockerfile") == "dockerfile")
        #expect(SyntaxHighlighter.language(forPath: "deploy/Dockerfile.dev") == "dockerfile")
        #expect(SyntaxHighlighter.language(forPath: "Makefile") == "makefile")
        #expect(SyntaxHighlighter.language(forPath: "GNUmakefile") == "makefile")
        #expect(SyntaxHighlighter.language(forPath: "/Users/me/.zshrc") == "shell")
        #expect(SyntaxHighlighter.language(forPath: "CMakeLists.txt") == "cmake")
        #expect(SyntaxHighlighter.language(forPath: "Gemfile") == "ruby")
        #expect(SyntaxHighlighter.language(forPath: "ios/Podfile") == "ruby")
        #expect(SyntaxHighlighter.language(forPath: ".gitignore") == "ignore")
        #expect(SyntaxHighlighter.language(forPath: ".env.local") == "dotenv")
        #expect(SyntaxHighlighter.language(forPath: "Cargo.lock") == "toml")
        #expect(SyntaxHighlighter.language(forPath: "go.mod") == "gomod")
        #expect(SyntaxHighlighter.language(forPath: "ore.toml") == "toml")
        #expect(SyntaxHighlighter.language(forPath: "Package.swift") == "swift")
        #expect(SyntaxHighlighter.language(forPath: "LICENSE") == "text")
        #expect(capture(of: "FROM", in: "FROM swift:6 AS build\nRUN make", language: "dockerfile") == "keyword")
        #expect(capture(of: "RUN", in: "FROM swift:6 AS build\nRUN make", language: "dockerfile") == "keyword")
        #expect(capture(of: "build", in: "all: build\n\tswift build", language: "makefile") == nil)
        #expect(capture(of: "all", in: "all: build\n\tswift build", language: "makefile") == "function")
    }

    @Test func typescriptIsItsOwnLanguage() {
        #expect(SyntaxHighlighter.canonicalName("ts") == "typescript")
        #expect(SyntaxHighlighter.canonicalName("tsx") == "tsx")
        #expect(SyntaxHighlighter.language(forPath: "src/app.ts") == "typescript")
        #expect(capture(of: "interface", in: "interface A {}", language: "ts") == "keyword")
        #expect(capture(of: "interface", in: "interface A {}", language: "js") == nil)
    }

    @Test func fenceNamesAndExtensionsMapToDefinitions() {
        let expected: [String: String] = [
            "sh": "shell", "zsh": "shell", "bash": "shell", "shell": "shell", "console": "shell",
            "yml": "yaml", "hpp": "cpp", "cc": "cpp", "h": "c", "m": "objc", "mm": "objcpp", "kt": "kotlin",
            "kts": "kotlin", "rs": "rust", "rb": "ruby", "ex": "elixir", "exs": "elixir", "hs": "haskell",
            "ml": "ocaml", "fs": "fsharp", "clj": "clojure", "ps1": "powershell", "tf": "hcl", "proto": "protobuf",
            "gql": "graphql", "sol": "solidity", "tex": "latex", "vim": "vim", "mdx": "markdown", "htm": "html",
            "xhtml": "html", "svg": "xml", "plist": "xml", "xib": "xml", "storyboard": "xml",
            "entitlements": "xml", "csproj": "xml", "scss": "scss", "jsonc": "jsonc", "json5": "jsonc",
            "c++": "cpp", "c#": "csharp", "golang": "go", "{r}": "r", "python,linenos": "python",
        ]
        for (raw, canonical) in expected {
            #expect(SyntaxHighlighter.canonicalName(raw) == canonical, "\(raw)")
        }
        let covered = """
        c cpp objc objcpp csharp java kotlin scala groovy go rust zig dart swift javascript typescript jsx tsx
        python ruby php perl lua r julia elixir erlang haskell ocaml fsharp clojure lisp shell fish powershell
        bat sql html xml css scss sass less jsonc json yaml toml ini dotenv markdown dockerfile makefile cmake
        graphql protobuf hcl nix solidity vue svelte diff latex vim nginx asm text
        """.split(whereSeparator: \.isWhitespace)
        for name in covered {
            #expect(LanguageRegistry.hasDefinition(String(name)), "\(name)")
        }
    }

    @Test func plainTextIsLeftAlone() {
        for name in ["text", "plaintext", "txt", "log"] {
            #expect(SyntaxLexer.tokens(for: "if x == \"y\" // z", language: SyntaxHighlighter.canonicalName(name)).isEmpty)
        }
    }

    // MARK: - Integration

    @Test func anUnknownLanguageStillGetsStringsAndComments() {
        let code = "let x = \"str\" // note"
        #expect(capture(of: "str", in: code, language: "made-up-lang") == "string")
        #expect(capture(of: "note", in: code, language: "made-up-lang") == "comment")
        #expect(color(of: "str", in: code, language: "made-up-lang") == SyntaxTheme.color(forCapture: "string"))
    }

    @Test func highlightLineColoursASingleLine() {
        let line = "    return \"ok\"  // done"
        let result = SyntaxHighlighter.shared.highlightLine(line, language: "ts", font: font)
        #expect(result.string == line)
        func colorAt(_ token: String) -> NSColor? {
            result.attribute(.foregroundColor, at: (line as NSString).range(of: token).location, effectiveRange: nil) as? NSColor
        }
        #expect(colorAt("return") == SyntaxTheme.color(forCapture: "keyword"))
        #expect(colorAt("ok") == SyntaxTheme.color(forCapture: "string"))
        #expect(colorAt("done") == SyntaxTheme.color(forCapture: "comment"))
        #expect(SyntaxHighlighter.shared.highlightLine("", language: "swift", font: font).length == 0)
    }

    @Test func rangesStayAlignedAroundMultiUnitCharacters() {
        let code = "let s = \"🎉 done\"; fn go() {}"
        #expect(capture(of: "fn", in: code, language: "rust") == "keyword")
        #expect(color(of: "fn", in: code, language: "rust") == SyntaxTheme.color(forCapture: "keyword"))
    }

    /// Every language over every prefix of an awkward sample: truncation is
    /// where an index runs past the end, and a debug build traps on it.
    @Test func everyLanguageSurvivesTruncatedInput() {
        let sample = """
        #!x\n<!-- <a b="c' {{ d }} \\ '\n${e $(f) #{g} \\(h) "i\\" 'j r#"k"# R"l(m)l" <<EOF\n@n #[o] -p: q; `r
        /* s /* t */ ``` ~~ **u _v [w](x) --- | y: |\n  z\n@@ -1 @@ + - 0x1F 1e5 .5 1'000 %a% :b ?c $$ \\[
        """
        let units = Array(sample.utf16)
        for name in LanguageDefinitions.all.map(\.name) {
            for length in stride(from: 0, through: units.count, by: 1) {
                let prefix = String(decoding: units[0..<length], as: UTF16.self)
                let prefixLength = (prefix as NSString).length
                for token in SyntaxLexer.tokens(for: prefix, language: name) {
                    #expect(token.start >= 0 && token.start < token.end && token.end <= prefixLength, "\(name)")
                }
            }
        }
    }

    @Test func largeFilesHighlightInLinearTime() {
        let unit = """
        // Comment with "quotes" and a URL: https://example.com
        export async function load(id: string): Promise<Item | null> {
          const url = `https://api.example.com/items/${id}?q=${encodeURIComponent("a#b")}`;
          const re = /^[a-z]+\\/\\d{2,}$/i;
          if (!re.test(id)) { return null; } /* block */
          return await fetch(url).then((r) => r.json()) as Item;
        }

        """
        let code = String(repeating: unit, count: 1_500_000 / unit.utf16.count)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let result = SyntaxHighlighter.shared.highlight(code, language: "typescript", font: font, cache: false)
            #expect(result.length == (code as NSString).length)
        }
        // Debug builds are several times slower than release, and CI machines
        // vary; this guards against accidental quadratic behaviour, not speed.
        #expect(elapsed < .seconds(5), "highlighting 1.5 MB took \(elapsed)")
    }
}

/// An extensionless script is identified by its `#!` line, not left as prose.
struct ShebangLanguageTests {
    @Test func anExtensionlessScriptIsIdentifiedByItsShebang() {
        #expect(SyntaxHighlighter.language(forPath: "bin/deploy", contents: "#!/bin/bash\necho hi") == "shell")
        #expect(SyntaxHighlighter.language(forPath: "tool", contents: "#!/usr/bin/env python3.12\n") == "python")
        #expect(SyntaxHighlighter.language(forPath: "run", contents: "#!/usr/bin/env -S node --no-warnings\n") == "javascript")
    }

    @Test func aNameOrExtensionStillWins() {
        #expect(SyntaxHighlighter.language(forPath: "build.py", contents: "#!/bin/sh\n") == "python")
        #expect(SyntaxHighlighter.language(forPath: "LICENSE", contents: "Apache License") == "text")
        #expect(SyntaxHighlighter.language(forPath: "notes", contents: "#!/opt/unknown-thing\n") == "text")
    }
}
