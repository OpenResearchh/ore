import Foundation

/// Every language the lexer knows, as data.
///
/// Word lists aim at what a reader needs to skim — control flow, declarations,
/// built-in types and literals — not at a complete grammar. A missing keyword
/// costs one uncoloured word; a wrong one (`type` coloured in every Go
/// variable name) costs trust, so contextual words are left out.
enum LanguageDefinitions {
    private static func w(_ words: String) -> [String] {
        words.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    typealias Def = LanguageDefinition
    typealias Str = LanguageDefinition.StringRule

    private static func cStyleComments(_ definition: inout Def) {
        definition.lineComments = ["//"]
        definition.blockComments = [.init(open: "/*", close: "*/")]
    }

    static let all: [LanguageDefinition] = [
        text, generic, c, cpp, objc, objcpp, csharp, java, kotlin, scala, groovy, go, rust, zig, dart, swift,
        javascript, typescript, jsx, tsx, python, ruby, php, perl, lua, r, julia, elixir, erlang, haskell,
        ocaml, fsharp, clojure, lisp, shell, fish, powershell, bat, sql, html, xml, vue, svelte, css, scss,
        sass, less, jsonc, json, yaml, toml, ini, ignore, dotenv, markdown, dockerfile, makefile, cmake,
        graphql, protobuf, hcl, nix, solidity, diff, latex, vim, nginx, asm, gomod,
    ]

    static let text = Def("text", lexer: .plain)

    /// Unknown languages: roughly what most code looks like. `#` needs a word
    /// boundary so it doesn't eat `a#b`, and single-line strings must close,
    /// so an apostrophe in prose stays prose.
    static let generic = Def("generic") {
        $0.lineComments = ["//", "#"]
        $0.commentsNeedBoundary = true
        $0.blockComments = [.init(open: "/*", close: "*/")]
        $0.strings = [Str("\"\"\"", multiline: true), Str("\""), Str("'"), Str("`")]
        $0.keywords = w("""
        func function fn def class struct enum interface trait let var const val if else elif for while loop
        return import from package use using include require public private protected static final async await
        try catch except finally throw throws raise new delete match case switch break continue yield impl
        in not and or do end then module export default
        """)
        $0.constants = w("true false null nil none None True False undefined")
        $0.builtinVariables = w("self this")
    }

    // MARK: - C family

    private static let cKeywords = w("""
    auto break case const continue default do else enum extern for goto if inline register restrict return
    sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn
    _Static_assert _Thread_local alignas alignof static_assert thread_local typeof
    """)
    private static let cTypes = w("""
    void char short int long float double signed unsigned bool _Bool _Complex size_t ssize_t ptrdiff_t
    intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t wchar_t char8_t
    char16_t char32_t FILE va_list
    """)

    static let c = Def("c") {
        cStyleComments(&$0)
        $0.strings = [Str("\"")]
        $0.stringPrefixes = ["l": .init(), "u": .init(), "u8": .init()]
        $0.charLiterals = true
        $0.preprocessor = true
        $0.keywords = cKeywords
        $0.types = cTypes
        $0.constants = w("NULL true false nullptr")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("struct enum union")
    }

    static let cpp = c.extended("cpp") {
        $0.keywords += w("""
        class namespace template typename public private protected virtual override final friend operator new
        delete throw try catch using noexcept constexpr constinit consteval decltype explicit mutable concept
        requires co_await co_return co_yield export import module static_cast dynamic_cast reinterpret_cast
        const_cast and or not xor
        """)
        $0.types += w("auto string vector map unordered_map set array optional unique_ptr shared_ptr")
        $0.builtinVariables = ["this"]
        $0.rawStrings = .cpp
        $0.digitSeparators = "'"
        $0.typeKeywords += w("class namespace concept")
    }

    private static func objcAdditions(_ definition: inout Def) {
        definition.strings.insert(Str("@\""), at: 0)
        definition.decorators = [.at]
        definition.keywords += w("""
        interface implementation end property synthesize dynamic protocol selector autoreleasepool try catch
        finally throw import optional required encode synchronized class nonatomic atomic strong weak copy
        assign readonly readwrite nullable nonnull
        """)
        definition.types += w("id instancetype SEL BOOL IMP NSInteger NSUInteger CGFloat")
        definition.constants += w("nil Nil YES NO")
        definition.builtinVariables += w("self super")
    }

    static let objc = c.extended("objc", objcAdditions)
    static let objcpp = cpp.extended("objcpp", objcAdditions)

    static let csharp = Def("csharp") {
        cStyleComments(&$0)
        $0.strings = [
            Str("\"\"\"", escapes: false, multiline: true),
            Str("$@\"", "\"", escapes: false, multiline: true, doubledClose: true, interpolation: .brace),
            Str("@$\"", "\"", escapes: false, multiline: true, doubledClose: true, interpolation: .brace),
            Str("$\"", "\"", interpolation: .brace),
            Str("@\"", "\"", escapes: false, multiline: true, doubledClose: true),
            Str("\""),
        ]
        $0.charLiterals = true
        $0.preprocessor = true
        $0.keywords = w("""
        abstract as base break case catch checked class const continue default delegate do else enum event
        explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new
        operator out override params private protected public readonly ref return sealed sizeof stackalloc
        static struct switch throw try typeof unchecked unsafe using virtual volatile while async await var
        when where yield get set init value record required file global partial nameof with and or not
        """)
        $0.types = w("bool byte sbyte char decimal double float int uint long ulong short ushort object string void dynamic nint nuint")
        $0.constants = w("true false null")
        $0.builtinVariables = w("this base")
        $0.capitalizedTypes = true
        $0.capitalizedCallsAreFunctions = true
        $0.typeKeywords = w("class struct interface enum record namespace")
    }

    static let java = Def("java") {
        cStyleComments(&$0)
        $0.strings = [Str("\"\"\"", multiline: true), Str("\"")]
        $0.charLiterals = true
        $0.decorators = [.at]
        $0.keywords = w("""
        abstract assert break case catch class continue default do else enum extends final finally for if
        implements import instanceof interface native new package private protected public return static
        strictfp switch synchronized throw throws transient try volatile while var record sealed permits
        non-sealed yield module requires exports opens uses provides
        """)
        $0.types = w("boolean byte char double float int long short void String Object Integer Long Double Boolean")
        $0.constants = w("true false null")
        $0.builtinVariables = w("this super")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("class interface enum record")
    }

    static let kotlin = Def("kotlin") {
        $0.lineComments = ["//"]
        $0.blockComments = [.init(open: "/*", close: "*/", nests: true)]
        $0.strings = [
            Str("\"\"\"", escapes: false, multiline: true, interpolation: .dollarBraceAndName),
            Str("\"", interpolation: .dollarBraceAndName),
        ]
        $0.charLiterals = true
        $0.decorators = [.at]
        $0.keywords = w("""
        as break class continue do else for fun if in interface is object package return super throw try
        typealias typeof val var when while by catch constructor delegate dynamic field file finally get import
        init param property receiver set setparam where abstract actual annotation companion const crossinline
        data enum expect external final infix inline inner internal lateinit noinline open operator out
        override private protected public reified sealed suspend tailrec vararg value
        """)
        $0.types = w("Int Long Short Byte Double Float Boolean Char String Unit Any Nothing Array List Map Set")
        $0.constants = w("true false null")
        $0.builtinVariables = w("this super it")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["fun"]
        $0.typeKeywords = w("class interface object typealias")
    }

    static let scala = Def("scala") {
        $0.lineComments = ["//"]
        $0.blockComments = [.init(open: "/*", close: "*/", nests: true)]
        $0.strings = [Str("\"\"\"", escapes: false, multiline: true), Str("\"")]
        $0.stringPrefixes = [
            "s": .init(interpolation: .dollarBraceAndName), "f": .init(interpolation: .dollarBraceAndName),
            "raw": .init(raw: true, interpolation: .dollarBraceAndName),
        ]
        $0.charLiterals = true
        $0.decorators = [.at]
        $0.keywords = w("""
        abstract case catch class def do else extends final finally for forSome if implicit import lazy match
        new object override package private protected return sealed throw trait try type val var while with
        yield given using enum export then end derives extension inline opaque transparent
        """)
        $0.types = w("Int Long Double Float Boolean Char String Unit Any AnyRef Nothing Option List Map Seq")
        $0.constants = w("true false null None Nil")
        $0.builtinVariables = w("this super")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["def"]
        $0.typeKeywords = w("class trait object type enum")
    }

    static let groovy = Def("groovy") {
        cStyleComments(&$0)
        $0.strings = [
            Str("'''", multiline: true),
            Str("\"\"\"", multiline: true, interpolation: .dollarBraceAndName),
            Str("'"),
            Str("\"", interpolation: .dollarBraceAndName),
        ]
        $0.decorators = [.at]
        $0.keywords = w("""
        abstract as assert break case catch class const continue def default do else enum extends final
        finally for goto if implements import in instanceof interface native new package private protected
        public return static super switch synchronized throw throws trait transient try var void volatile while
        plugins dependencies repositories apply
        """)
        $0.types = w("boolean byte char double float int long short String Object")
        $0.constants = w("true false null")
        $0.builtinVariables = w("this super it")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("class interface enum trait")
    }

    static let go = Def("go") {
        cStyleComments(&$0)
        $0.strings = [Str("\""), Str("`", escapes: false, multiline: true)]
        $0.charLiterals = true
        $0.keywords = w("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var
        """)
        $0.types = w("""
        bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8
        uint16 uint32 uint64 uintptr any comparable
        """)
        $0.constants = w("true false nil iota")
        $0.builtins = w("append cap clear close complex copy delete imag len make max min new panic print println real recover")
        $0.functionKeywords = ["func"]
        $0.typeKeywords = ["type"]
    }

    static let rust = Def("rust") {
        $0.lineComments = ["//"]
        $0.blockComments = [.init(open: "/*", close: "*/", nests: true)]
        $0.strings = [Str("\"", multiline: true)]
        $0.stringPrefixes = ["b": .init(), "c": .init()]
        $0.rawStrings = .rust
        $0.charLiterals = true
        $0.quoteLabels = true
        $0.decorators = [.hashBracket]
        $0.identifierSuffixes = "!"
        $0.keywords = w("""
        as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move
        mut pub ref return static struct super trait type union unsafe use where while yield macro_rules
        """)
        $0.types = w("""
        i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box
        """)
        $0.constants = w("true false None Some Ok Err")
        $0.builtinVariables = w("self Self")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["fn"]
        $0.typeKeywords = w("struct enum trait type union")
    }

    static let zig = Def("zig") {
        $0.lineComments = ["//"]
        $0.strings = [Str("\\\\", "\n", escapes: false), Str("\"")]
        $0.charLiterals = true
        $0.decorators = [.at]
        $0.keywords = w("""
        addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const
        continue defer else enum errdefer error export extern fn for if inline noalias nosuspend noinline opaque
        or orelse packed pub resume return linksection struct suspend switch test threadlocal try union
        unreachable usingnamespace var volatile while
        """)
        $0.types = w("""
        i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f16 f32 f64 f80 f128 bool void type anyerror
        noreturn c_int c_uint c_long comptime_int comptime_float anyopaque
        """)
        $0.constants = w("true false null undefined")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["fn"]
    }

    static let dart = Def("dart") {
        $0.lineComments = ["//"]
        $0.blockComments = [.init(open: "/*", close: "*/", nests: true)]
        $0.strings = [
            Str("'''", multiline: true, interpolation: .dollarBraceAndName),
            Str("\"\"\"", multiline: true, interpolation: .dollarBraceAndName),
            Str("'", interpolation: .dollarBraceAndName),
            Str("\"", interpolation: .dollarBraceAndName),
        ]
        $0.stringPrefixes = ["r": .init(raw: true)]
        $0.decorators = [.at]
        $0.keywords = w("""
        abstract as assert async await base break case catch class const continue covariant default deferred do
        dynamic else enum export extends extension external factory final finally for get hide if implements
        import in interface is late library mixin new of on operator part required rethrow return sealed set
        show static super switch sync throw try typedef var when while with yield
        """)
        $0.types = w("int double num String bool void List Map Set Future Stream Object Iterable Never Function")
        $0.constants = w("true false null")
        $0.builtinVariables = w("this super")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("class mixin enum extension typedef")
    }

    /// Swift normally goes through tree-sitter; this covers diff lines and the
    /// case where the grammar fails to load.
    static let swift = Def("swift") {
        $0.lineComments = ["//"]
        $0.blockComments = [.init(open: "/*", close: "*/", nests: true)]
        $0.strings = [
            Str("\"\"\"", multiline: true, interpolation: .backslashParen),
            Str("\"", interpolation: .backslashParen),
        ]
        $0.rawStrings = .swift
        $0.decorators = [.at]
        $0.sigils = [.init(character: "#", kind: .keyword)]
        $0.keywords = w("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch
        continue default defer do else fallthrough for guard if in repeat return throw switch where while as
        is try await async throws actor some any nonisolated isolated consume borrowing consuming mutating
        nonmutating override final required convenience lazy weak unowned indirect package macro sending
        """)
        $0.types = w("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float String Bool Character Void Any AnyObject Never")
        $0.constants = w("true false nil")
        $0.builtinVariables = w("self Self super")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["func"]
        $0.typeKeywords = w("struct class enum protocol actor extension typealias associatedtype")
    }

    // MARK: - Web

    static let javascript = Def("javascript") {
        cStyleComments(&$0)
        $0.strings = [Str("\""), Str("'"), Str("`", multiline: true, interpolation: .dollarBrace)]
        $0.regexLiterals = true
        $0.jsx = true
        $0.decorators = [.at]
        $0.identifierStart = "$"
        $0.keywords = w("""
        async await break case catch class const continue debugger default delete do else export extends
        finally for from function get if import in instanceof let new of return set static super switch throw
        try typeof var void while with yield as
        """)
        $0.constants = w("true false null undefined NaN Infinity")
        $0.builtinVariables = w("this arguments globalThis window document console process module exports")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["function"]
        $0.typeKeywords = ["class"]
    }

    static let typescript = javascript.extended("typescript") {
        // `<T>(x)` is a generic, not an element, outside .tsx.
        $0.jsx = false
        $0.keywords += w("""
        abstract accessor any asserts declare enum implements infer interface is keyof namespace never override
        private protected public readonly satisfies type unique unknown out
        """)
        $0.types = w("string number boolean bigint symbol object void unknown never any")
        $0.typeKeywords += w("interface type enum namespace")
    }

    static let jsx = javascript.extended("jsx") { _ in }
    static let tsx = typescript.extended("tsx") { $0.jsx = true }

    static let html = Def("html", lexer: .markup(.html))
    static let xml = Def("xml", lexer: .markup(.xml))
    static let vue = Def("vue", lexer: .markup(.vue))
    static let svelte = Def("svelte", lexer: .markup(.svelte))
    static let css = Def("css", lexer: .css(.css))
    static let scss = Def("scss", lexer: .css(.scss))
    static let sass = Def("sass", lexer: .css(.sass))
    static let less = Def("less", lexer: .css(.less))

    static let graphql = Def("graphql") {
        $0.lineComments = ["#"]
        $0.strings = [Str("\"\"\"", multiline: true), Str("\"")]
        $0.decorators = [.at]
        $0.sigils = [.init(character: "$", kind: .variableSpecial)]
        $0.keywords = w("query mutation subscription fragment on type interface union enum input scalar schema extend directive implements repeatable")
        $0.types = w("Int Float String Boolean ID")
        $0.constants = w("true false null")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("type interface union enum input scalar fragment")
    }

    // MARK: - Scripting

    static let python = Def("python") {
        $0.lineComments = ["#"]
        $0.strings = [
            Str("\"\"\"", multiline: true), Str("'''", multiline: true), Str("\""), Str("'"),
        ]
        let formatted = LanguageDefinition.StringPrefix(interpolation: .brace)
        let rawFormatted = LanguageDefinition.StringPrefix(raw: true, interpolation: .brace)
        $0.stringPrefixes = [
            "r": .init(raw: true), "u": .init(), "b": .init(), "rb": .init(raw: true), "br": .init(raw: true),
            "f": formatted, "fr": rawFormatted, "rf": rawFormatted, "t": formatted,
        ]
        $0.decorators = [.at]
        $0.keywords = w("""
        and as assert async await break class continue def del elif else except finally for from global if
        import in is lambda nonlocal not or pass raise return try while with yield match case
        """)
        $0.constants = w("True False None NotImplemented Ellipsis __name__ __file__")
        $0.builtinVariables = w("self cls")
        $0.types = w("int float str bytes bool list dict set tuple object complex frozenset bytearray")
        $0.builtins = w("""
        print len range open isinstance issubclass super enumerate zip map filter sorted reversed min max sum
        abs any all repr hasattr getattr setattr iter next format input id hash dir vars callable round divmod
        chr ord property staticmethod classmethod
        """)
        $0.capitalizedTypes = true
        $0.functionKeywords = ["def"]
        $0.typeKeywords = ["class"]
    }

    static let ruby = Def("ruby") {
        $0.lineComments = ["#"]
        $0.blockComments = [.init(open: "=begin", close: "=end")]
        $0.strings = [
            Str("\"", multiline: true, interpolation: .hashBrace),
            Str("'", multiline: true),
            Str("`", multiline: true, interpolation: .hashBrace),
        ]
        $0.heredocs = true
        $0.regexLiterals = true
        $0.identifierSuffixes = "?!"
        $0.sigils = [
            .init(character: "@", kind: .variableSpecial),
            .init(character: "$", kind: .variableSpecial),
            .init(character: ":", kind: .constant),
        ]
        $0.keywords = w("""
        BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module next
        not or redo rescue retry return super then undef unless until when while yield require require_relative
        include extend prepend attr_accessor attr_reader attr_writer private protected public raise lambda proc
        loop
        """)
        $0.constants = w("true false nil __FILE__ __LINE__ __dir__")
        $0.builtinVariables = ["self"]
        $0.builtins = w("puts print p pp")
        $0.capitalizedTypes = true
        $0.functionKeywords = ["def"]
        $0.typeKeywords = w("class module")
    }

    static let php = Def("php") {
        $0.lineComments = ["//", "#"]
        $0.blockComments = [.init(open: "/*", close: "*/")]
        $0.strings = [Str("\"", multiline: true, interpolation: .shell), Str("'", multiline: true)]
        $0.heredocs = true
        $0.decorators = [.hashBracket]
        $0.caseInsensitive = true
        $0.sigils = [.init(character: "$", kind: .variableSpecial)]
        $0.keywords = w("""
        abstract and array as break callable case catch class clone const continue declare default do echo else
        elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for
        foreach function global goto if implements include include_once instanceof insteadof interface isset
        list match namespace new or print private protected public readonly require require_once return static
        switch throw trait try unset use var while xor yield
        """)
        $0.types = w("int float bool string void mixed never object iterable")
        $0.constants = w("true false null")
        $0.builtinVariables = w("this self parent")
        $0.capitalizedTypes = true
        $0.functionKeywords = w("function fn")
        $0.typeKeywords = w("class interface trait enum")
    }

    static let perl = Def("perl") {
        $0.lineComments = ["#"]
        $0.blockComments = [.init(open: "=pod", close: "=cut")]
        $0.strings = [
            Str("\"", multiline: true, interpolation: .shell), Str("'", multiline: true), Str("`"),
        ]
        $0.heredocs = true
        $0.regexLiterals = true
        $0.sigils = [
            .init(character: "$", kind: .variableSpecial, braces: true, specials: "_0123456789@!&/\\,;."),
            .init(character: "@", kind: .variableSpecial, specials: "_"),
            .init(character: "%", kind: .variableSpecial),
        ]
        $0.keywords = w("""
        my our local sub package use require no if elsif else unless while until for foreach last next redo
        return do eval die warn print printf say defined undef bless ref scalar shift push pop unshift splice
        keys values each exists delete wantarray qw q qq and or not eq ne lt gt le ge cmp BEGIN END
        """)
        $0.functionKeywords = ["sub"]
        $0.typeKeywords = ["package"]
    }

    static let lua = Def("lua") {
        $0.lineComments = ["--"]
        $0.blockComments = [.init(open: "--[[", close: "]]")]
        $0.strings = [Str("\""), Str("'"), Str("[[", "]]", escapes: false, multiline: true)]
        $0.keywords = w("and break do else elseif end for function goto if in local not or repeat return then until while")
        $0.constants = w("true false nil")
        $0.builtinVariables = w("self _G _ENV")
        $0.builtins = w("print pairs ipairs require type tostring tonumber setmetatable getmetatable pcall xpcall error assert select next rawget rawset unpack")
        $0.functionKeywords = ["function"]
    }

    static let r = Def("r") {
        $0.lineComments = ["#"]
        $0.strings = [Str("\"", multiline: true), Str("'", multiline: true)]
        $0.identifierChars = "."
        $0.keywords = w("function if else for while repeat in next break return library require")
        $0.constants = w("TRUE FALSE NULL NA NaN Inf NA_integer_ NA_real_ NA_character_")
    }

    static let julia = Def("julia") {
        $0.lineComments = ["#"]
        $0.blockComments = [.init(open: "#=", close: "=#", nests: true)]
        $0.strings = [
            Str("\"\"\"", multiline: true, interpolation: .dollarBraceAndName),
            Str("\"", interpolation: .dollarBraceAndName),
            Str("`", multiline: true),
        ]
        $0.charLiterals = true
        $0.decorators = [.at]
        $0.identifierSuffixes = "!"
        $0.keywords = w("""
        function end if elseif else for while begin let local global const return break continue module
        baremodule using import export struct mutable abstract type primitive quote macro do try catch finally
        in isa where
        """)
        $0.types = w("Int Int8 Int16 Int32 Int64 UInt Float32 Float64 String Bool Vector Array Dict Any Nothing Symbol Char")
        $0.constants = w("true false nothing missing Inf NaN")
        $0.capitalizedTypes = true
        $0.functionKeywords = w("function macro")
        $0.typeKeywords = w("struct type")
    }

    static let elixir = Def("elixir") {
        $0.lineComments = ["#"]
        $0.strings = [
            Str("\"\"\"", multiline: true, interpolation: .hashBrace),
            Str("'''", multiline: true),
            Str("\"", multiline: true, interpolation: .hashBrace),
            Str("'", multiline: true),
        ]
        $0.identifierSuffixes = "?!"
        $0.sigils = [
            .init(character: ":", kind: .constant),
            .init(character: "@", kind: .attribute),
        ]
        $0.keywords = w("""
        def defp defmodule defmacro defmacrop defstruct defprotocol defimpl defdelegate defguard defexception
        do end fn if else unless case cond with for receive try catch rescue after raise quote unquote import
        require alias use when in and or not
        """)
        $0.constants = w("true false nil")
        $0.builtinVariables = w("__MODULE__ __DIR__ __ENV__ __CALLER__")
        $0.capitalizedTypes = true
        $0.functionKeywords = w("def defp defmacro defmacrop defguard")
    }

    static let erlang = Def("erlang") {
        $0.lineComments = ["%"]
        $0.strings = [Str("\"", multiline: true), Str("'", kind: .constant)]
        $0.decorators = [.lineStartDash]
        $0.sigils = [.init(character: "?", kind: .constant)]
        $0.keywords = w("""
        after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse
        receive rem try when xor maybe else
        """)
        $0.constants = w("true false undefined ok error")
    }

    static let haskell = Def("haskell") {
        $0.lineComments = ["--"]
        $0.blockComments = [.init(open: "{-", close: "-}", nests: true)]
        $0.strings = [Str("\"")]
        $0.charLiterals = true
        $0.identifierChars = "'"
        $0.keywords = w("""
        case class data default deriving do else foreign if import in infix infixl infixr instance let module
        newtype of then type where qualified as hiding forall mdo family pattern
        """)
        $0.constants = w("True False Nothing")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("data newtype type")
    }

    static let ocaml = Def("ocaml") {
        $0.blockComments = [.init(open: "(*", close: "*)", nests: true)]
        $0.strings = [Str("\"", multiline: true), Str("{|", "|}", escapes: false, multiline: true)]
        $0.charLiterals = true
        $0.quoteLabels = true
        $0.identifierChars = "'"
        $0.keywords = w("""
        and as assert begin class constraint do done downto else end exception external for fun function functor
        if in include inherit initializer lazy let match method module mutable new nonrec object of open or
        private rec sig struct then to try type val virtual when while with
        """)
        $0.types = w("int float string bool char unit list option array ref exn bytes")
        $0.constants = w("true false None Some")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("type module")
    }

    static let fsharp = Def("fsharp") {
        $0.lineComments = ["//"]
        $0.blockComments = [.init(open: "(*", close: "*)")]
        $0.strings = [
            Str("\"\"\"", escapes: false, multiline: true),
            Str("$\"", "\"", interpolation: .brace),
            Str("@\"", "\"", escapes: false, multiline: true, doubledClose: true),
            Str("\"", multiline: true),
        ]
        $0.charLiterals = true
        $0.quoteLabels = true
        $0.keywords = w("""
        abstract and as assert base begin class default delegate do done downcast downto elif else end exception
        extern finally fixed for fun function global if in inherit inline interface internal lazy let match
        member module mutable namespace new not of open or override private public rec return select sig static
        struct then to try type upcast use val void when while with yield async task
        """)
        $0.types = w("int float string bool unit char list option seq array decimal byte obj")
        $0.constants = w("true false null None Some")
        $0.capitalizedTypes = true
        $0.capitalizedCallsAreFunctions = true
        $0.typeKeywords = w("type module namespace")
    }

    static let clojure = Def("clojure") {
        $0.lineComments = [";"]
        $0.strings = [Str("#\"", "\"", kind: .stringSpecial), Str("\"", multiline: true)]
        $0.sigils = [.init(character: ":", kind: .constant)]
        $0.identifierStart = "*!?<>=&"
        $0.identifierChars = "-!?*+<>=/.'#"
        $0.keywords = w("""
        def defn defn- defmacro defmulti defmethod defprotocol defrecord deftype defonce fn let letfn loop recur
        if if-not if-let when when-not when-let cond condp case do doseq dotimes for ns require import use try
        catch finally throw quote var binding and or not new set! -> ->>
        """)
        $0.constants = w("true false nil")
        $0.functionCalls = false
        $0.lispCalls = true
    }

    static let lisp = Def("lisp") {
        $0.lineComments = [";"]
        $0.blockComments = [.init(open: "#|", close: "|#", nests: true)]
        $0.strings = [Str("\"", multiline: true)]
        $0.sigils = [.init(character: ":", kind: .constant)]
        $0.identifierStart = "*!?<>="
        $0.identifierChars = "-!?*+<>=/.:%&"
        $0.keywords = w("""
        defun defmacro defvar defparameter defconstant defclass defmethod defgeneric defstruct defcustom define
        define-syntax define-record-type lambda let let* letrec letrec* if cond when unless case and or not progn
        prog1 begin do dolist dotimes loop setq setf set! quote quasiquote require provide module import export
        use-package with-eval-after-load interactive
        """)
        $0.constants = w("t nil true false")
        $0.functionCalls = false
        $0.lispCalls = true
    }

    // MARK: - Shells

    private static let shellKeywords = w("""
    if then else elif fi case esac for select while until do done in function time coproc return exit break
    continue export local readonly declare typeset unset shift source alias unalias eval exec trap set shopt
    let test
    """)

    static let shell = Def("shell") {
        $0.lineComments = ["#"]
        $0.commentsNeedBoundary = true
        $0.strings = [
            Str("$'", "'"),
            Str("\"", multiline: true, interpolation: .shell),
            Str("'", escapes: false, multiline: true),
            Str("`", multiline: true),
        ]
        $0.heredocs = true
        $0.sigils = [
            .init(character: "$", kind: .variableSpecial, braces: true, parens: true, specials: "@*#?$!-0123456789"),
        ]
        $0.keywords = shellKeywords
        $0.constants = w("true false")
        $0.builtins = w("""
        echo printf read cd pwd pushd popd dirs kill wait jobs bg fg umask ulimit getopts hash type command builtin
        enable help history logout mapfile readarray sudo
        """)
        $0.keys = .init(separators: "=", spacesBeforeSeparator: false, after: ";&|({", kind: .variableSpecial)
    }

    static let fish = shell.extended("fish") {
        $0.keywords += w("end begin not and or set argparse switch emit status contains string math functions")
        $0.keys = nil
    }

    static let powershell = Def("powershell") {
        $0.lineComments = ["#"]
        $0.blockComments = [.init(open: "<#", close: "#>")]
        $0.strings = [
            Str("@\"", "\"@", escapes: false, multiline: true, interpolation: .shell),
            Str("@'", "'@", escapes: false, multiline: true),
            Str("\"", escapes: false, multiline: true, interpolation: .shell),
            Str("'", escapes: false, multiline: true, doubledClose: true),
        ]
        $0.caseInsensitive = true
        $0.identifierChars = "-"
        $0.sigils = [.init(character: "$", kind: .variableSpecial, braces: true, parens: true, specials: "_?^$")]
        $0.keywords = w("""
        begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for
        foreach from function hidden if in param process return static switch throw trap try until using var
        while workflow eq ne gt lt ge le like notlike match notmatch contains notcontains notin and or not xor
        band bor is isnot replace split join
        """)
        $0.types = w("string int long bool double object array hashtable switch void datetime pscustomobject")
        $0.capitalizedTypes = true
        $0.capitalizedCallsAreFunctions = true
        $0.functionKeywords = w("function filter")
        $0.typeKeywords = w("class enum")
    }

    static let bat = Def("bat") {
        $0.lineStartComments = ["rem", "@rem", "::"]
        $0.strings = [Str("\"", escapes: false)]
        $0.caseInsensitive = true
        $0.sigils = [
            .init(character: "%", kind: .variableSpecial, specials: "0123456789*~", closer: "%"),
            .init(character: ":", kind: .label),
        ]
        $0.keywords = w("""
        echo set if else for in do goto call exit not exist defined errorlevel equ neq lss leq gtr geq setlocal
        endlocal shift pause cls title start cd pushd popd off on nul
        """)
        $0.functionCalls = false
    }

    // MARK: - Data and configuration

    static let sql = Def("sql") {
        $0.lineComments = ["--"]
        $0.blockComments = [.init(open: "/*", close: "*/")]
        $0.strings = [
            Str("'", escapes: false, multiline: true, doubledClose: true),
            Str("$$", escapes: false, multiline: true),
            Str("\"", escapes: false, kind: .property),
            Str("`", escapes: false, kind: .property),
        ]
        $0.caseInsensitive = true
        $0.sigils = [
            .init(character: "@", kind: .variableSpecial),
            .init(character: ":", kind: .variableSpecial),
            .init(character: "$", kind: .variableSpecial, specials: "0123456789"),
        ]
        $0.keywords = w("""
        select from where and or not insert into values update set delete create table view index drop alter add
        column constraint primary key foreign references unique check default is in exists between like ilike
        join inner left right outer full cross on using group by order asc desc having limit offset union all
        distinct as case when then else end begin commit rollback transaction grant revoke with recursive
        returning if replace trigger procedure function returns language declare cursor fetch open close loop
        while for return database schema use show describe explain analyze vacuum truncate merge conflict do
        nothing over partition window rows range unbounded preceding following current lateral natural cascade
        restrict temporary temp sequence extension owner to collate each execute except intersect materialized
        """)
        $0.types = w("""
        int integer bigint smallint tinyint serial bigserial decimal numeric real float double precision varchar
        char character text boolean bool date time timestamp timestamptz interval uuid json jsonb blob bytea
        money xml
        """)
        $0.constants = w("true false null unknown current_date current_time current_timestamp")
    }

    static let jsonc = Def("jsonc") {
        cStyleComments(&$0)
        $0.strings = [Str("\""), Str("'")]
        $0.constants = w("true false null Infinity NaN")
        $0.identifierStart = "$"
        $0.keys = .init(separators: ":", statementStart: false, quoted: true)
        $0.functionCalls = false
    }

    /// JSON is tree-sitter's; this covers diff lines and the parse-failure path.
    static let json = jsonc.extended("json") { _ in }

    static let yaml = Def("yaml", lexer: .yaml)

    static let toml = Def("toml") {
        $0.lineComments = ["#"]
        $0.strings = [
            Str("\"\"\"", multiline: true), Str("'''", escapes: false, multiline: true),
            Str("\""), Str("'", escapes: false),
        ]
        $0.sectionHeaders = true
        $0.identifierChars = "-."
        $0.keys = .init(separators: "=", after: "{,", quoted: true)
        $0.constants = w("true false inf nan")
        $0.functionCalls = false
    }

    static let ini = Def("ini") {
        $0.lineStartComments = [";", "#"]
        $0.strings = [Str("\"", escapes: false)]
        $0.sectionHeaders = true
        $0.identifierChars = "-."
        $0.keys = .init(separators: "=:", kind: .property)
        $0.constants = w("true false yes no on off")
        $0.caseInsensitive = true
        $0.functionCalls = false
    }

    static let ignore = Def("ignore") {
        $0.lineStartComments = ["#"]
        $0.functionCalls = false
    }

    static let dotenv = Def("dotenv") {
        $0.lineComments = ["#"]
        $0.commentsNeedBoundary = true
        $0.strings = [
            Str("\"", multiline: true, interpolation: .shell), Str("'", escapes: false, multiline: true),
        ]
        $0.sigils = [.init(character: "$", kind: .variableSpecial, braces: true)]
        $0.identifierChars = "."
        $0.keywords = ["export"]
        $0.constants = w("true false")
        $0.keys = .init(separators: "=", spacesBeforeSeparator: false)
        $0.functionCalls = false
    }

    static let markdown = Def("markdown", lexer: .markdown)
    static let diff = Def("diff", lexer: .diff)

    // MARK: - Build and infrastructure

    static let dockerfile = Def("dockerfile") {
        $0.lineComments = ["#"]
        $0.commentsNeedBoundary = true
        $0.strings = [Str("\""), Str("'", escapes: false)]
        $0.heredocs = true
        $0.sigils = [.init(character: "$", kind: .variableSpecial, braces: true)]
        $0.lineStartKeywords = w("""
        from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal
        healthcheck shell
        """)
        $0.keywords = ["AS", "as"]
        $0.keys = .init(separators: "=", spacesBeforeSeparator: false)
        $0.functionCalls = false
    }

    static let makefile = Def("makefile") {
        $0.lineComments = ["#"]
        $0.commentsNeedBoundary = true
        $0.strings = [Str("\""), Str("'", escapes: false)]
        $0.sigils = [
            .init(character: "$", kind: .variableSpecial, braces: true, parensAreVariables: true, specials: "@<^+?*%$|"),
        ]
        $0.identifierChars = "-./%"
        $0.keywords = w("""
        ifeq ifneq ifdef ifndef else endif include -include sinclude define endef export unexport override vpath
        .PHONY .DEFAULT .SUFFIXES .PRECIOUS .SILENT
        """)
        $0.identifierStart = "."
        $0.keys = .init(separators: ":", kind: .function)
        $0.functionCalls = false
    }

    static let cmake = Def("cmake") {
        $0.blockComments = [.init(open: "#[[", close: "]]")]
        $0.lineComments = ["#"]
        $0.strings = [Str("\"", multiline: true, interpolation: .dollarBrace)]
        $0.sigils = [.init(character: "$", kind: .variableSpecial, braces: true)]
        $0.caseInsensitive = true
        $0.keywords = w("""
        if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return break
        continue block endblock
        """)
        $0.constants = w("on off true false yes no")
        $0.capitalizedTypes = true
    }

    static let protobuf = Def("protobuf") {
        cStyleComments(&$0)
        $0.strings = [Str("\""), Str("'")]
        $0.keywords = w("""
        syntax edition package import option message enum service rpc returns stream oneof map reserved
        extensions extend to max optional required repeated public weak group
        """)
        $0.types = w("double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes")
        $0.constants = w("true false")
        $0.capitalizedTypes = true
        $0.typeKeywords = w("message enum service")
    }

    static let hcl = Def("hcl") {
        $0.lineComments = ["#", "//"]
        $0.blockComments = [.init(open: "/*", close: "*/")]
        $0.strings = [Str("\"", interpolation: .dollarBrace)]
        $0.heredocs = true
        $0.identifierChars = "-"
        $0.keywords = w("""
        resource data variable output module provider locals terraform backend required_providers for in if else
        endif for_each count depends_on lifecycle dynamic content moved import check removed
        """)
        $0.constants = w("true false null")
        $0.keys = .init(separators: "=", after: "{,")
    }

    static let nix = Def("nix") {
        $0.lineComments = ["#"]
        $0.blockComments = [.init(open: "/*", close: "*/")]
        $0.strings = [
            Str("''", escapes: false, multiline: true, interpolation: .dollarBrace),
            Str("\"", multiline: true, interpolation: .dollarBrace),
        ]
        $0.identifierChars = "-'"
        $0.keywords = w("let in with rec inherit if then else assert or")
        $0.constants = w("true false null")
        $0.builtins = w("builtins import map toString throw abort baseNameOf derivation fetchTarball")
        $0.keys = .init(separators: "=", after: "{;")
        $0.functionCalls = false
    }

    static let solidity = Def("solidity") {
        cStyleComments(&$0)
        $0.strings = [Str("\""), Str("'")]
        $0.stringPrefixes = ["hex": .init(), "unicode": .init()]
        $0.keywords = w("""
        pragma solidity contract interface library abstract function modifier event emit error revert require
        assert return returns if else for while do break continue new delete import using is struct enum mapping
        public private internal external view pure payable constant immutable override virtual memory storage
        calldata constructor fallback receive try catch unchecked assembly let indexed anonymous type
        """)
        $0.types = w("address bool string bytes byte int uint")
            + stride(from: 8, through: 256, by: 8).flatMap { ["uint\($0)", "int\($0)"] }
            + (1...32).map { "bytes\($0)" }
        $0.constants = w("true false wei gwei ether seconds minutes hours days weeks")
        $0.builtinVariables = w("this super msg block tx")
        $0.capitalizedTypes = true
        $0.functionKeywords = w("function modifier event")
        $0.typeKeywords = w("contract interface library struct enum")
    }

    static let gomod = Def("gomod") {
        $0.lineComments = ["//"]
        $0.strings = [Str("\""), Str("`", escapes: false)]
        $0.keywords = w("module go require replace exclude retract toolchain godebug tool")
        $0.functionCalls = false
    }

    // MARK: - Everything else

    static let latex = Def("latex") {
        $0.lineComments = ["%"]
        $0.strings = [
            Str("$$", escapes: false, multiline: true, kind: .stringSpecial),
            Str("$", escapes: false, kind: .stringSpecial),
        ]
        $0.sigils = [.init(character: "\\", kind: .keyword, escapesPunctuation: true)]
        $0.functionCalls = false
    }

    static let vim = Def("vim") {
        $0.lineStartComments = ["\""]
        $0.strings = [Str("'", escapes: false, doubledClose: true), Str("\"")]
        $0.identifierChars = ":#"
        $0.keywords = w("""
        function endfunction func endfunc let unlet if elseif else endif for endfor while endwhile try catch
        finally endtry return call execute exe set setlocal autocmd augroup command map nmap vmap xmap imap
        noremap nnoremap vnoremap xnoremap inoremap syntax highlight hi source echo echom normal silent abort
        range dict in is isnot filetype plugin
        """)
        $0.constants = w("v:true v:false v:null")
    }

    static let nginx = Def("nginx") {
        $0.lineComments = ["#"]
        $0.commentsNeedBoundary = true
        $0.strings = [Str("\""), Str("'")]
        $0.sigils = [.init(character: "$", kind: .variableSpecial, braces: true)]
        $0.identifierChars = "-."
        $0.keywords = w("server location http events upstream if map include return rewrite")
        $0.constants = w("on off")
        $0.firstWordKind = .property
        $0.functionCalls = false
    }

    static let asm = Def("asm") {
        $0.lineComments = [";", "//"]
        $0.lineStartComments = ["#"]
        $0.blockComments = [.init(open: "/*", close: "*/")]
        $0.strings = [Str("\""), Str("'")]
        $0.caseInsensitive = true
        $0.identifierStart = "."
        $0.sigils = [.init(character: "%", kind: .variableSpecial)]
        $0.keywords = w("""
        mov movq movl movb movzx movsx lea push pop call ret jmp je jne jz jnz jg jge jl jle ja jb jae jbe cmp
        test add sub mul imul div idiv inc dec and or xor not neg shl shr sal sar nop int syscall leave enter
        adr adrp ldr str ldp stp bl blr br b cbz cbnz beq bne bgt blt svc
        section segment global extern db dw dd dq resb resw resd resq times equ bits org
        .section .text .data .bss .rodata .globl .global .align .p2align .byte .word .long .quad .ascii .asciz
        .string .equ .set .extern .type .size .zero .space
        """)
        $0.types = w("""
        rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15 eax ebx ecx edx esi edi ebp esp ax bx cx
        dx al bl cl dl ah bh ch dh rip eip sp lr pc xzr wzr fp
        """) + (0...30).flatMap { ["x\($0)", "w\($0)"] }
        $0.keys = .init(separators: ":", kind: .label)
        $0.functionCalls = false
    }
}
