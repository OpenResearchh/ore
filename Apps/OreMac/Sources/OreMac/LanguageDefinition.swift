import Foundation

/// A declarative description of how a language looks to the lexer.
///
/// Most languages are "C-like enough": comments, strings, numbers and words,
/// differing only in which markers and words they use. Describing them as data
/// keeps adding a language to a few lines, and keeps the scanner one loop that
/// is tuned once. Languages whose shape isn't token-oriented (markup, CSS,
/// Markdown, YAML, diffs) name a dedicated `lexer` instead.
struct LanguageDefinition: Sendable {
    enum Lexer: Sendable {
        case plain
        case code
        case markup(MarkupFlavor)
        case css(CSSFlavor)
        case markdown
        case yaml
        case diff
    }

    enum MarkupFlavor: Sendable { case html, xml, vue, svelte }
    enum CSSFlavor: Sendable { case css, scss, sass, less }

    /// Where a string lets code back in. The embedded expression is lexed as
    /// the host language; its delimiters are `punctuation.special`.
    enum Interpolation: Sendable {
        case none
        /// `${expr}` (JavaScript templates, Groovy, HCL, Nix).
        case dollarBrace
        /// `${expr}` and `$name` (Kotlin, Dart, Scala, Groovy, PHP, Perl, shell).
        case dollarBraceAndName
        /// `#{expr}` (Ruby, Elixir, CoffeeScript, Crystal).
        case hashBrace
        /// `\(expr)` (Swift).
        case backslashParen
        /// `{expr}` with `{{` as a literal brace (Python f-strings, C# `$""`).
        case brace
        /// `$name` and `${name}` as variables, `$(command)` as code (shells,
        /// PHP, Perl, .env).
        case shell
    }

    struct StringRule: Sendable {
        var open: String
        var close: String
        var escapes = true
        var multiline = false
        /// `''` inside `'…'` is a literal quote (SQL, Pascal, YAML, PowerShell).
        var doubledClose = false
        var interpolation: Interpolation = .none
        var kind: SyntaxTokenKind = .string

        init(
            _ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false,
            doubledClose: Bool = false, interpolation: Interpolation = .none, kind: SyntaxTokenKind = .string
        ) {
            self.open = open
            self.close = close ?? open
            self.escapes = escapes
            self.multiline = multiline
            self.doubledClose = doubledClose
            self.interpolation = interpolation
            self.kind = kind
        }
    }

    struct BlockComment: Sendable {
        var open: String
        var close: String
        var nests = false
    }

    /// A character that turns the following word into something else:
    /// `$name` (shell, PHP, Perl), `@ivar` (Ruby), `:atom` (Elixir, Ruby,
    /// Clojure), `\command` (LaTeX).
    struct Sigil: Sendable {
        var character: Character
        var kind: SyntaxTokenKind
        /// `${…}` is one variable token.
        var braces = false
        /// `$(…)` is one variable token (Make); otherwise `$(` is marked as
        /// special punctuation and its contents lexed normally (shell).
        var parensAreVariables = false
        var parens = false
        /// Single characters that complete the sigil on their own (`$@`, `$?`).
        var specials = ""
        /// A non-word character after it is an escape (`\{` in LaTeX).
        var escapesPunctuation = false
        /// The variable runs to this character (`%PATH%` in batch files).
        var closer: Character?
    }

    enum Decorator: Sendable {
        /// `@name` / `@a.b` (Python, Java, Kotlin, TypeScript, Swift, Dart).
        case at
        /// `#[…]` / `#![…]` (Rust).
        case hashBracket
        /// `-module(…)` at the start of a line (Erlang).
        case lineStartDash
    }

    /// `key = value` style names: TOML/INI keys, shell assignments, JSON5
    /// object keys, HCL/Nix attributes.
    struct KeyRule: Sendable {
        var separators: String
        var spacesBeforeSeparator = true
        /// Only the first word of a line (or after one of `after`) is a key.
        var statementStart = true
        var after = ""
        var kind: SyntaxTokenKind = .property
        /// A quoted string followed by the separator is a key too.
        var quoted = false
    }

    struct StringPrefix: Sendable {
        var raw = false
        var interpolation: Interpolation = .none
    }

    struct RawStrings: OptionSet, Sendable {
        let rawValue: Int
        /// `r"…"`, `r#"…"#`, `br"…"`.
        static let rust = RawStrings(rawValue: 1)
        /// `#"…"#`, `#"""…"""#`.
        static let swift = RawStrings(rawValue: 2)
        /// `R"delim(…)delim"`.
        static let cpp = RawStrings(rawValue: 4)
    }

    var name: String
    var lexer: Lexer = .code

    var lineComments: [String] = []
    /// Comment markers that only count as the first thing on a line (`"` in
    /// Vim script, `REM` in batch files).
    var lineStartComments: [String] = []
    /// `#` in shell starts a comment only at a word boundary: `a#b` is a word.
    var commentsNeedBoundary = false
    var blockComments: [BlockComment] = []

    var strings: [StringRule] = []
    /// Words that may sit directly before a quote and belong to the string
    /// (`f"…"`, `b'…'`, `u8"…"`, `@"…"`), keyed lowercase.
    var stringPrefixes: [String: StringPrefix] = [:]
    var rawStrings: RawStrings = []
    /// `'` only opens a short character literal; otherwise it is punctuation,
    /// or a label (`'a` lifetimes) when `quoteLabels` is set.
    var charLiterals = false
    var quoteLabels = false
    var heredocs = false
    var regexLiterals = false
    var jsx = false

    var keywords: [String] = []
    var types: [String] = []
    var constants: [String] = []
    var builtins: [String] = []
    var builtinVariables: [String] = []
    /// Keywords that only count as the first word on a line (Dockerfile).
    var lineStartKeywords: [String] = []
    var caseInsensitive = false

    var identifierStart = ""
    var identifierChars = ""
    /// Trailing `?`/`!` that belong to a name (Ruby, Elixir) unless `=` follows.
    var identifierSuffixes = ""
    var sigils: [Sigil] = []
    var decorators: [Decorator] = []
    /// `#include`, `#define`, `#if` at the start of a line.
    var preprocessor = false
    /// `name(` is a call.
    var functionCalls = true
    /// `(name …)` is a call.
    var lispCalls = false
    /// `Name` is a type and `NAME` a constant.
    var capitalizedTypes = false
    /// ...except `Name(`, which is a call (C#'s PascalCase methods).
    var capitalizedCallsAreFunctions = false
    /// The first word on a line is a directive (nginx).
    var firstWordKind: SyntaxTokenKind?
    /// The word after one of these is a function name (`def`, `fn`).
    var functionKeywords: [String] = []
    /// The word after one of these is a type name (`class`, `struct`).
    var typeKeywords: [String] = []
    var keys: KeyRule?
    /// `[section]` on a line of its own (INI, TOML).
    var sectionHeaders = false
    var digitSeparators = "_"
    /// Number suffixes like CSS units and `%`.
    var percentNumbers = false

    init(_ name: String, lexer: Lexer = .code, _ configure: (inout LanguageDefinition) -> Void = { _ in }) {
        self.name = name
        self.lexer = lexer
        configure(&self)
    }

    /// A copy under another name, for dialects (TypeScript from JavaScript).
    func extended(_ name: String, _ configure: (inout LanguageDefinition) -> Void) -> LanguageDefinition {
        var copy = self
        copy.name = name
        configure(&copy)
        return copy
    }
}

/// A definition with its word lists hashed and its markers converted to UTF-16,
/// built once per language on first use.
final class CompiledLanguage: Sendable {
    struct CompiledString: Sendable {
        var rule: LanguageDefinition.StringRule
        var open: [UInt16]
        var close: [UInt16]
    }

    struct CompiledBlockComment: Sendable {
        var open: [UInt16]
        var close: [UInt16]
        var nests: Bool
    }

    let definition: LanguageDefinition
    let lexer: LanguageDefinition.Lexer
    let lineComments: [[UInt16]]
    let lineStartComments: [[UInt16]]
    let blockComments: [CompiledBlockComment]
    let strings: [CompiledString]
    let words: WordTable
    let lineStartWords: WordTable
    /// The word after these keywords is a function (`.function`) or type (`.type`).
    let definers: WordTable
    let identifierStart: UnitSet
    let identifierChars: UnitSet
    let identifierSuffixes: UnitSet
    let digitSeparators: UnitSet
    /// First units of every comment and string opener, so most characters
    /// skip those checks with one bit test.
    let openers: UnitSet
    let sigils: [UInt16: LanguageDefinition.Sigil]
    let keySeparators: UnitSet
    let keyAfter: UnitSet
    let hasPrefixes: Bool
    let capitalizedCallsAreFunctions: Bool
    let capitalizedTypes: Bool
    let functionCalls: Bool
    let lispCalls: Bool
    let commentsNeedBoundary: Bool
    let keys: LanguageDefinition.KeyRule?
    let rawStrings: LanguageDefinition.RawStrings
    let stringPrefixes: [String: LanguageDefinition.StringPrefix]
    let firstWordKind: SyntaxTokenKind?

    init(_ definition: LanguageDefinition) {
        self.definition = definition
        lexer = definition.lexer
        lineComments = definition.lineComments.map { Array($0.utf16) }
        lineStartComments = definition.lineStartComments.map { Array($0.lowercased().utf16) }
        blockComments = definition.blockComments.map {
            CompiledBlockComment(open: Array($0.open.utf16), close: Array($0.close.utf16), nests: $0.nests)
        }
        strings = definition.strings.map {
            CompiledString(rule: $0, open: Array($0.open.utf16), close: Array($0.close.utf16))
        }

        var words = WordTable(caseInsensitive: definition.caseInsensitive)
        words.insert(definition.keywords, as: .keyword)
        words.insert(definition.constants, as: .constantBuiltin)
        words.insert(definition.builtinVariables, as: .variableBuiltin)
        words.insert(definition.types, as: .typeBuiltin)
        words.insert(definition.builtins, as: .functionBuiltin)
        self.words = words

        var lineStartWords = WordTable(caseInsensitive: true)
        lineStartWords.insert(definition.lineStartKeywords, as: .keyword)
        self.lineStartWords = lineStartWords

        var definers = WordTable(caseInsensitive: definition.caseInsensitive)
        definers.insert(definition.functionKeywords, as: .function)
        definers.insert(definition.typeKeywords, as: .type)
        self.definers = definers

        identifierStart = UnitSet(definition.identifierStart)
        identifierChars = UnitSet(definition.identifierChars + definition.identifierStart)
        identifierSuffixes = UnitSet(definition.identifierSuffixes)
        digitSeparators = UnitSet(definition.digitSeparators)

        var openers = UnitSet()
        for marker in lineComments + lineStartComments { if let first = marker.first { openers.insert(first) } }
        for comment in blockComments { if let first = comment.open.first { openers.insert(first) } }
        for string in strings { if let first = string.open.first { openers.insert(first) } }
        // Line-start comments are matched case-insensitively (`REM`).
        for marker in lineStartComments {
            if let first = marker.first, Unit.isLower(first) { openers.insert(first - 32) }
        }
        self.openers = openers

        var sigils: [UInt16: LanguageDefinition.Sigil] = [:]
        for sigil in definition.sigils {
            if let unit = String(sigil.character).utf16.first { sigils[unit] = sigil }
        }
        self.sigils = sigils
        keySeparators = UnitSet(definition.keys?.separators ?? "")
        keyAfter = UnitSet(definition.keys?.after ?? "")
        hasPrefixes = !definition.stringPrefixes.isEmpty
        capitalizedCallsAreFunctions = definition.capitalizedCallsAreFunctions
        capitalizedTypes = definition.capitalizedTypes
        functionCalls = definition.functionCalls
        lispCalls = definition.lispCalls
        commentsNeedBoundary = definition.commentsNeedBoundary
        keys = definition.keys
        rawStrings = definition.rawStrings
        stringPrefixes = definition.stringPrefixes
        firstWordKind = definition.firstWordKind
    }
}

/// Canonical language names, and the definitions behind them.
enum LanguageRegistry {
    /// Built once: hashing every language's words costs a few milliseconds,
    /// paid on the first highlight rather than on every one.
    private static let compiled: [String: CompiledLanguage] = {
        var table: [String: CompiledLanguage] = [:]
        for definition in LanguageDefinitions.all {
            table[definition.name] = CompiledLanguage(definition)
        }
        return table
    }()

    private static let generic = CompiledLanguage(LanguageDefinitions.generic)

    /// The definition for a canonical name. Unknown and missing names get the
    /// generic C-like definition: unhighlighted code in an app for reading code
    /// is a worse outcome than approximate highlighting.
    static func definition(for name: String?) -> CompiledLanguage {
        guard let name else { return generic }
        return compiled[name] ?? generic
    }

    static func hasDefinition(_ name: String) -> Bool {
        compiled[name] != nil
    }

    /// Normalises a fence info string or file extension.
    ///
    /// A fence can carry more than a language (```` ```swift title=foo.swift ````,
    /// ```` ```{r} ````, ```` ```python,linenos ````), so only the first word is
    /// read, minus the braces and dots some tools wrap it in.
    static func canonicalName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            .first.map(String.init) ?? trimmed
        var lowered = first.lowercased()
        lowered = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        if let brace = lowered.firstIndex(of: "{") { lowered = String(lowered[..<brace]) }
        return aliases[lowered] ?? lowered
    }

    static func language(forPath path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        let lowered = file.lowercased()
        if let known = fileNames[lowered] { return known }
        if lowered.hasPrefix(".env") { return "dotenv" }
        if lowered.hasPrefix("dockerfile") || lowered.hasSuffix(".dockerfile") { return "dockerfile" }
        if lowered.hasPrefix("makefile") { return "makefile" }
        if lowered.hasSuffix(".lock") { return lockFiles[lowered] }
        if lowered.hasPrefix(".") && !lowered.dropFirst().contains(".") {
            // Dotfiles with no further extension: `.zshrc`, `.gitignore`.
            return dotFiles[lowered]
        }
        let ext = (file as NSString).pathExtension.lowercased()
        // Extensionless files that aren't known by name are usually prose
        // (LICENSE, AUTHORS): colouring apostrophes and URLs as code is worse
        // than leaving them alone.
        guard !ext.isEmpty else { return "text" }
        return canonicalName(ext)
    }

    /// `language(forPath:)`, except that a script with no telling name says
    /// what it is on its first line: `bin/deploy` starting `#!/usr/bin/env
    /// bash` is shell, not prose.
    static func language(forPath path: String, contents: String) -> String? {
        let byPath = language(forPath: path)
        guard byPath == "text", contents.hasPrefix("#!") else { return byPath }
        let firstLine = contents.prefix { $0 != "\n" }.dropFirst(2)
        let words = firstLine.split(separator: " ").map(String.init)
        guard var interpreter = words.first.map({ ($0 as NSString).lastPathComponent })
        else { return byPath }
        // `#!/usr/bin/env -S node --flag`: the program is env's first operand.
        if interpreter == "env" {
            guard let operand = words.dropFirst().first(where: { !$0.hasPrefix("-") })
            else { return byPath }
            interpreter = operand
        }
        // `python3.12` is python.
        let program = String(interpreter.prefix { $0.isLetter || $0 == "-" })
        return interpreters[program] ?? byPath
    }

    private static let interpreters: [String: String] = [
        "sh": "shell", "bash": "shell", "zsh": "shell", "dash": "shell", "ksh": "shell",
        "fish": "fish",
        "python": "python", "pypy": "python",
        "node": "javascript", "deno": "typescript", "bun": "javascript", "ts-node": "typescript",
        "ruby": "ruby", "perl": "perl", "php": "php", "lua": "lua",
        "Rscript": "r", "julia": "julia", "elixir": "elixir", "swift": "swift",
        "pwsh": "powershell",
    ]

    private static let fileNames: [String: String] = [
        "containerfile": "dockerfile",
        "gnumakefile": "makefile",
        "justfile": "makefile",
        "cmakelists.txt": "cmake",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "brewfile": "ruby",
        "fastfile": "ruby", "appfile": "ruby", "matchfile": "ruby", "guardfile": "ruby",
        "vagrantfile": "ruby", "dangerfile": "ruby", "berksfile": "ruby", "capfile": "ruby",
        "jenkinsfile": "groovy",
        "build": "python", "workspace": "python", "build.bazel": "python", "workspace.bazel": "python",
        "pipfile": "toml",
        "go.mod": "gomod", "go.work": "gomod", "go.sum": "text",
        "procfile": "yaml",
        "nginx.conf": "nginx",
        "requirements.txt": "ini",
        "license": "text", "licence": "text", "copying": "text", "notice": "text", "authors": "text",
        "readme": "markdown", "changelog": "markdown",
    ]

    private static let lockFiles: [String: String] = [
        "cargo.lock": "toml", "poetry.lock": "toml", "uv.lock": "toml", "pdm.lock": "toml",
        "gopkg.lock": "toml",
        "flake.lock": "jsonc", "composer.lock": "jsonc", "pipfile.lock": "jsonc", "deno.lock": "jsonc",
        "yarn.lock": "yaml", "podfile.lock": "yaml", "pubspec.lock": "yaml", "pnpm-lock.yaml": "yaml",
        "mix.lock": "elixir", "package.resolved": "jsonc",
    ]

    private static let dotFiles: [String: String] = [
        ".bashrc": "shell", ".bash_profile": "shell", ".bash_login": "shell", ".bash_logout": "shell",
        ".bash_aliases": "shell", ".zshrc": "shell", ".zshenv": "shell", ".zprofile": "shell",
        ".zlogin": "shell", ".zlogout": "shell", ".profile": "shell", ".kshrc": "shell",
        ".envrc": "shell",
        ".gitignore": "ignore", ".dockerignore": "ignore", ".npmignore": "ignore",
        ".prettierignore": "ignore", ".eslintignore": "ignore", ".hgignore": "ignore",
        ".gitattributes": "ignore", ".swiftlint": "yaml",
        ".gitconfig": "ini", ".gitmodules": "ini", ".editorconfig": "ini", ".npmrc": "ini",
        ".vimrc": "vim", ".gvimrc": "vim", ".exrc": "vim",
        ".babelrc": "jsonc", ".eslintrc": "jsonc", ".prettierrc": "jsonc",
    ]

    /// Names people write in fences and file extensions, mapped to a definition.
    private static let aliases: [String: String] = {
        var table: [String: String] = [:]
        func map(_ canonical: String, _ names: String) {
            for name in names.split(separator: " ") { table[String(name)] = canonical }
        }
        map("text", "plaintext plain txt log none nohighlight output")
        map("c", "h")
        map("cpp", "c++ cc cxx hpp hh hxx h++ ipp inl tpp ino cuda cu metal")
        map("objc", "objective-c objectivec m")
        map("objcpp", "objective-c++ objectivecpp mm")
        map("csharp", "c# cs csx cake")
        map("java", "jav")
        map("kotlin", "kt kts")
        map("scala", "sc sbt")
        map("groovy", "gradle gvy")
        map("go", "golang")
        map("rust", "rs")
        map("zig", "zon")
        map("javascript", "js mjs cjs node es6 ecmascript")
        map("typescript", "ts mts cts")
        map("jsx", "react")
        map("python", "py pyw pyi py3 python3 gyp bzl starlark sage ipython")
        map("ruby", "rb gemspec podspec rake ru erb jbuilder")
        map("php", "phtml php3 php4 php5 php7 php8")
        map("perl", "pl pm t pod perl5")
        map("lua", "luau")
        map("r", "rscript rmd")
        map("julia", "jl")
        map("elixir", "ex exs heex")
        map("erlang", "erl hrl")
        map("haskell", "hs lhs")
        map("ocaml", "ml mli")
        map("fsharp", "f# fs fsi fsx")
        map("clojure", "clj cljs cljc edn")
        map("lisp", "el elisp emacs-lisp lsp cl common-lisp scm scheme rkt racket ss fnl fennel")
        map("shell", "sh bash zsh ksh console shellsession shell-session terminal command ash dash sh-session")
        map("fish", "fish")
        map("powershell", "ps1 psm1 psd1 pwsh posh ps")
        map("bat", "cmd batch dos")
        map("sql", "mysql postgresql postgres psql plsql sqlite tsql pgsql ddl dml")
        map("html", "htm xhtml shtml jinja jinja2 j2 twig liquid hbs handlebars mustache ejs njk")
        map("xml", "svg plist xib storyboard entitlements csproj fsproj vbproj props targets xaml xsd xsl xslt rss atom wsdl resx nuspec pom manifest kml gpx dae")
        map("css", "pcss postcss")
        map("scss", "scss")
        map("sass", "sass")
        map("less", "less")
        map("jsonc", "json5 jsonl ndjson geojson webmanifest har babelrc code-workspace")
        map("json", "json")
        map("yaml", "yml")
        map("toml", "toml")
        map("ini", "cfg conf config properties prefs desktop service inf reg gitconfig")
        map("dotenv", "env")
        map("markdown", "md mdx mkd mkdn mdown rmarkdown")
        map("dockerfile", "docker containerfile")
        map("makefile", "make mk mak just")
        map("cmake", "cmake")
        map("graphql", "gql graphqls")
        map("protobuf", "proto proto3")
        map("hcl", "tf tfvars terraform hcl nomad")
        map("nix", "nix")
        map("solidity", "sol")
        map("vue", "vue")
        map("svelte", "svelte")
        map("diff", "patch udiff")
        map("latex", "tex sty cls bib bibtex ltx context")
        map("vim", "vimscript viml vimrc")
        map("nginx", "nginxconf")
        map("asm", "assembly s nasm masm x86asm armasm gas")
        map("dart", "dart")
        map("swift", "swift")
        map("ignore", "gitignore dockerignore")
        return table
    }()
}
