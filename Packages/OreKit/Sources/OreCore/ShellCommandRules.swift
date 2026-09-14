import Foundation

/// The rule table, part one: commands judged by name alone, file and network
/// tools, and shells. Developer tooling — git, GitHub, package managers,
/// build systems — is in `ShellCommandTools.swift`.
extension ShellCommandClassifier {
    static func rule(
        for name: String,
        invokedAs invocation: String,
        arguments: [String],
        segment: ShellCommandLine.Segment,
        depth: Int
    ) -> ShellCommandVerdict {
        if let fixed = fixedVerdicts[name] { return fixed }
        let operands = ProjectPaths.operands(arguments)

        switch name {
        case "command":
            if let flag = arguments.first, flag == "-v" || flag == "-V" {
                return .inspect("looks up a command")
            }
            return reclassify(arguments, in: segment, depth: depth)
        case "env":
            guard let rest = envCommand(arguments) else {
                return .unknown("uses env options ORE doesn't check")
            }
            if rest.isEmpty { return .attention("prints environment variables, which can include secrets") }
            return reclassify(rest, in: segment, depth: depth)
        case "export":
            let assignments = arguments.filter(ShellCommandLine.isAssignment)
            if assignments.isEmpty { return .attention("prints environment variables, which can include secrets") }
            for assignment in assignments {
                if let reason = Environment.risk(ofAssigning: assignment) { return .attention(reason) }
            }
            return .inspect("sets a variable")
        case "set":
            return arguments.isEmpty
                ? .attention("prints variables, which can include secrets")
                : .inspect("sets shell options")
        case "sh", "bash", "zsh", "dash", "ksh", "fish":
            return shell(arguments, depth: depth, readsFromPipe: segment.readsFromPipe)
        case "find":
            return find(arguments)
        case "rg", "ripgrep":
            let preprocesses = arguments.contains { $0 == "--pre" || $0.hasPrefix("--pre=") }
            return preprocesses
                ? .attention("runs a preprocessor on every file it searches")
                : .inspect("searches files")
        case "sed", "gsed":
            return sed(arguments)
        case "awk", "gawk", "nawk", "mawk":
            return awk(arguments)
        case "sort":
            let targets = sortOutputs(arguments)
            guard !targets.isEmpty else { return .inspect("sorts text") }
            return writes(to: targets, as: "writes sorted output to a file")
        case "tee":
            return writes(to: operands, as: "writes a file")
        case "uniq", "xxd":
            // Both write their second file operand: `uniq in out`, `xxd -r in out`.
            return operands.count > 1
                ? writes(to: Array(operands.dropFirst()), as: "writes a file")
                : .inspect("only reads")
        case "mkdir", "touch", "cp", "mv", "ln", "rmdir", "patch", "install", "ditto":
            return writes(to: operands, as: "changes files in the project")
        case "chmod":
            return writes(to: Array(operands.dropFirst()), as: "changes file permissions")
        case "tar", "bsdtar":
            if arguments.contains(where: tarRunsAProgram) {
                return .attention("runs a program while it reads the archive")
            }
            let flags = arguments.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) } ?? ""
            if flags.contains("t"), !flags.contains("x"), !flags.contains("c") {
                return .inspect("lists an archive")
            }
            return writes(to: operands, as: "unpacks or creates an archive")
        case "unzip":
            if arguments.contains("-l") || arguments.contains("-v") { return .inspect("lists an archive") }
            return writes(to: operands, as: "unpacks an archive")
        case "zip", "gzip", "gunzip", "bzip2", "xz", "zstd":
            return writes(to: operands, as: "compresses or unpacks files")
        case "curl", "wget", "http", "https", "xh":
            return network(name, arguments)
        case "defaults":
            let reads: Set = ["read", "read-type", "domains", "find"]
            return reads.contains(arguments.first ?? "")
                ? .inspect("reads app preferences")
                : .attention("changes app preferences")
        case "xcode-select":
            let reads: Set = ["-p", "--print-path", "-v", "--version"]
            return arguments.allSatisfy(reads.contains)
                ? .inspect("shows the developer tools path")
                : .attention("changes system settings")
        case "sysctl":
            let writes = arguments.contains { $0 == "-w" || $0.contains("=") }
            return writes ? .attention("changes system settings") : .inspect("reads system settings")
        case "python", "python3", "node", "ruby", "perl", "php", "deno", "lua", "java":
            let versionFlags: Set = ["--version", "-V", "-v", "-version"]
            if arguments.count == 1, versionFlags.contains(arguments[0]) {
                return .inspect("prints a version")
            }
            return .unknown("runs code")
        case "git":
            return git(arguments)
        case "gh":
            return gitHub(arguments)
        case "npm", "pnpm", "yarn", "bun":
            return javaScript(name, arguments)
        case "pip", "pip3", "uv", "poetry", "pipenv":
            return python(name, arguments)
        case "cargo":
            return cargo(arguments)
        case "go":
            return goTool(arguments)
        case "swift":
            return swift(arguments)
        case "xcodebuild":
            return xcodebuild(arguments)
        case "make", "gmake", "just", "ninja", "rake", "gradle", "gradlew", "mvn", "mvnw":
            return task(arguments)
        case "brew":
            return brew(arguments)
        case "docker", "podman", "docker-compose":
            return container(name, arguments)
        case "bundle":
            return bundler(arguments, segment: segment, depth: depth)
        default:
            break
        }

        if inspectCommands.contains(name) { return .inspect("only reads") }
        if let tooling = checkTool(name, arguments) { return tooling }
        if invocation.contains("/") {
            return ProjectPaths.isInside(invocation)
                ? .unknown("runs a project script")
                : .attention("runs a program outside the project")
        }
        return .unknown("isn't a command ORE recognises")
    }

    // MARK: - Judged by name alone

    static let fixedVerdicts: [String: ShellCommandVerdict] = {
        var table: [String: ShellCommandVerdict] = [:]
        func add(_ names: [String], _ verdict: ShellCommandVerdict) {
            for name in names { table[name] = verdict }
        }
        add(["sudo", "su", "doas", "pkexec"], .attention("runs with administrator privileges"))
        add(["rm", "unlink", "shred", "srm", "trash"], .attention("deletes files"))
        add([
            "launchctl", "systemctl", "diskutil", "dd", "mkfs", "fdisk", "mount", "umount",
            "csrutil", "spctl", "xattr", "chflags", "chown", "chgrp", "shutdown", "reboot", "halt",
            "pmset", "networksetup", "scutil", "nvram", "tccutil", "kextload", "softwareupdate",
        ], .attention("changes system settings"))
        add(["kill", "killall", "pkill"], .attention("stops running processes"))
        add(["security"], .attention("reads or changes the keychain"))
        add(["printenv"], .attention("prints environment variables, which can include secrets"))
        add(["history"], .attention("prints shell history, which can include secrets"))
        add(
            ["ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "socat", "mosh"],
            .attention("connects to another machine")
        )
        add(["osascript", "automator", "shortcuts"], .attention("controls other apps"))
        add(["eval", "exec", "source", "."], .attention("runs code ORE can't read"))
        add(["xargs", "parallel"], .attention("runs a command for every input line"))
        add(["crontab", "at", "batch"], .attention("schedules work to run later"))
        add(["nohup", "disown", "screen", "tmux"], .attention("keeps running after the turn ends"))
        add([
            "kubectl", "helm", "terraform", "pulumi", "aws", "gcloud", "az", "fly", "flyctl",
            "vercel", "netlify", "heroku", "firebase", "wrangler", "railway", "doctl", "supabase",
        ], .attention("uses your cloud account"))
        add(["npx", "bunx", "pnpx"], .attention("may download and run a package"))
        add(["passwd", "chsh", "dscl", "sysadminctl"], .attention("changes user accounts"))
        add(["mail", "sendmail"], .attention("sends email"))
        add(["open"], .unknown("opens an app or link"))
        return table
    }()

    /// Commands that only ever look. Anything that can write, delete or run
    /// something else is deliberately absent, and lands in `unknown`.
    static let inspectCommands: Set<String> = [
        "ls", "pwd", "cat", "bat", "head", "tail", "less", "more", "wc", "file", "stat",
        "du", "df", "tree", "which", "whereis", "type", "echo", "printf", "date", "cal",
        "uname", "whoami", "id", "groups", "hostname", "basename", "dirname", "realpath",
        "readlink", "diff", "cmp", "comm", "cut", "tr", "nl", "fold", "column",
        "paste", "join", "rev", "jq", "yq", "true", "false", "test", "[", "[[", ":",
        "sw_vers", "uptime", "cd", "pushd", "popd", "grep", "egrep", "fgrep", "ag", "ack",
        "fd", "md5", "md5sum", "shasum", "sha1sum", "sha256sum", "cksum", "hexdump",
        "od", "strings", "otool", "nm", "lipo", "sleep", "seq", "expr", "ps", "pgrep", "lsof",
        "man", "tldr", "locale", "arch", "nproc", "mdfind", "mdls", "cloc", "tokei", "read",
        "exit", "wait", "unset", "alias", "fsck_hfs_dryrun",
    ]

    // MARK: - Files

    /// What `env` will run once its own options are read, or nil for an option
    /// that changes where or how that command runs. Dropping every dashed
    /// argument let `env --chdir=/etc cat passwd` pass as a bare `cat passwd`,
    /// and `-S` re-splits a string into a different command entirely.
    static func envCommand(_ arguments: [String]) -> [String]? {
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            let option = arguments[index]
            index += 1
            switch option {
            case "--":
                return Array(arguments[index...])
            case "-", "-i", "--ignore-environment", "-0", "--null", "-v", "--debug":
                continue
            case "-u", "--unset":
                guard index < arguments.count else { return nil }
                index += 1
            default:
                if option.hasPrefix("--unset=") { continue }
                return nil
            }
        }
        return Array(arguments[index...])
    }

    /// Every file `sort` would write. BSD and GNU sort both take the output
    /// attached as well as separate — `-oout`, `-ro out`, `--output=out` — and
    /// matching only the separate spellings let the others read as sorting.
    static func sortOutputs(_ arguments: [String]) -> [String] {
        var targets: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" { break }
            if argument == "--output" {
                if index < arguments.count { targets.append(arguments[index]); index += 1 }
            } else if argument.hasPrefix("--output=") {
                targets.append(String(argument.dropFirst("--output=".count)))
            } else if argument.hasPrefix("-"), !argument.hasPrefix("--"),
                      let flag = argument.dropFirst().firstIndex(of: "o") {
                let attached = argument[argument.index(after: flag)...]
                if !attached.isEmpty {
                    targets.append(String(attached))
                } else if index < arguments.count {
                    targets.append(arguments[index])
                    index += 1
                }
            }
        }
        return targets
    }

    /// GNU tar options that start a program whatever mode the archive is opened
    /// in: `tar -tf a.tar --checkpoint-action=exec=id` lists *and* runs.
    static func tarRunsAProgram(_ argument: String) -> Bool {
        let programs = [
            "--to-command", "--checkpoint-action", "--use-compress-program",
            "--info-script", "--new-volume-script", "--rsh-command", "--rmt-command",
        ]
        return programs.contains { argument == $0 || argument.hasPrefix($0 + "=") }
            || argument == "-I" || argument == "-F"
    }

    /// An edit when every path stays inside the project, attention otherwise.
    static func writes(to paths: [String], as reason: String) -> ShellCommandVerdict {
        paths.allSatisfy(ProjectPaths.isInside)
            ? .edit(reason)
            : .attention("changes files outside the project")
    }

    static func find(_ arguments: [String]) -> ShellCommandVerdict {
        let flags = Set(arguments)
        if !flags.isDisjoint(with: ["-exec", "-execdir", "-ok", "-okdir"]) {
            return .attention("runs a command on every file it finds")
        }
        if flags.contains("-delete") { return .attention("deletes files") }
        if !flags.isDisjoint(with: ["-fprint", "-fprint0", "-fprintf", "-fls"]) {
            return .attention("writes its results to a file")
        }
        return .inspect("searches for files")
    }

    /// `w` writes a file and `e` runs a command, and both hide in the script
    /// text rather than in a flag. A command may be preceded by an address
    /// (`1e id`, `2,4w out`, `$!e id`), so the leading address forms are
    /// skipped before looking for the letter.
    static let sedSideEffect = try? NSRegularExpression(
        pattern: #"(^|[;{}\n]|/[gIip0-9]*)\s*(?:\d+|\$)?(?:\s*,\s*(?:\d+|\$))?\s*!?\s*[wWe](\s|$)"#
    )

    static let sedScriptOptions: Set<String> = ["-e", "--expression"]
    static let sedScriptFileOptions: Set<String> = ["-f", "--file"]
    /// GNU takes the suffix attached, BSD takes it as the next word, so the
    /// value is only ever read when it is attached and the following word is
    /// left to be read as a script or a file.
    static let sedInPlaceOptions: Set<String> = ["-i", "-I", "--in-place"]
    static let sedFlagOptions: Set<String> = [
        "-n", "--quiet", "--silent", "-E", "-r", "--regexp-extended", "-s", "--separate",
        "-z", "--null-data", "-u", "--unbuffered", "-a", "--posix", "--debug", "--sandbox",
        "--follow-symlinks", "--help", "--version",
    ]

    static func sed(_ arguments: [String]) -> ShellCommandVerdict {
        let parsed = parseArguments(
            arguments,
            valueOptions: sedScriptOptions.union(sedScriptFileOptions),
            attachedValueOptions: sedInPlaceOptions,
            flagOptions: sedFlagOptions
        )
        if parsed.unreadableOption != nil { return .unknown("uses a sed option ORE can't read") }
        if parsed.has(sedScriptFileOptions) { return .unknown("runs a sed script") }

        let explicitScripts = parsed.values(of: sedScriptOptions)
        if let pattern = sedSideEffect, (explicitScripts + parsed.operands).contains(where: {
            pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }) {
            return .attention("writes files or runs commands from its script")
        }
        guard parsed.has(sedInPlaceOptions) else { return .inspect("prints transformed text") }
        let files = explicitScripts.isEmpty ? Array(parsed.operands.dropFirst()) : parsed.operands
        return writes(to: files, as: "edits files in place")
    }

    static let awkProgramOptions: Set<String> = ["-e", "--source"]
    static let awkProgramFileOptions: Set<String> = ["-f", "--file"]
    static let awkValueOptions: Set<String> = [
        "-F", "--field-separator", "-v", "--assign",
    ]
    static let awkFlagOptions: Set<String> = [
        "-V", "--version", "-h", "--help", "--posix", "--traditional", "-c", "--csv",
    ]

    /// awk reads its program from the first operand, so an option that takes a
    /// separate value can push the program out of a naive "first word without a
    /// dash" scan — `awk -v x=1 'BEGIN{system("id")}'` looked like `x=1`. The
    /// options are parsed so the program is found wherever it is, and an option
    /// ORE has no grammar for stops the scan rather than being guessed at.
    static func awk(_ arguments: [String]) -> ShellCommandVerdict {
        let parsed = parseArguments(
            arguments,
            valueOptions: awkValueOptions.union(awkProgramOptions).union(awkProgramFileOptions),
            flagOptions: awkFlagOptions
        )
        if parsed.unreadableOption != nil { return .unknown("uses an awk option ORE can't read") }
        if parsed.has(awkProgramFileOptions) { return .unknown("runs an awk script") }

        let programs = parsed.values(of: awkProgramOptions) + parsed.operands
        let sideEffects = ["system(", "getline", "|", ">", "ENVIRON"]
        return programs.contains(where: { program in sideEffects.contains(where: program.contains) })
            ? .attention("can run commands or write files from its program")
            : .inspect("prints transformed text")
    }

    // MARK: - Option grammar

    /// One argument list split into options, their values and operands.
    struct ParsedArguments {
        var options: [(name: String, value: String?)] = []
        var operands: [String] = []
        /// An option outside the declared grammar. While this is set ORE
        /// cannot tell an option's value from an operand, so the rule that
        /// asked for the scan must refuse to judge the command.
        var unreadableOption: String?

        func has(_ names: Set<String>) -> Bool {
            options.contains { names.contains($0.name) }
        }

        func values(of names: Set<String>) -> [String] {
            options.filter { names.contains($0.name) }.compactMap(\.value)
        }
    }

    /// Splits `arguments` with a declared option grammar. Short names are
    /// written `-v`, long names `--assign`. `valueOptions` take a value either
    /// attached or as the following word; `attachedValueOptions` only take one
    /// when it is attached. Clustered short flags and `--` are understood.
    /// Anything else ends the scan and is reported.
    static func parseArguments(
        _ arguments: [String],
        valueOptions: Set<String>,
        attachedValueOptions: Set<String> = [],
        flagOptions: Set<String>
    ) -> ParsedArguments {
        var result = ParsedArguments()
        var rest = arguments[...]
        var parsingOptions = true

        while let head = rest.first {
            rest = rest.dropFirst()
            guard parsingOptions, head.hasPrefix("-"), head != "-" else {
                result.operands.append(head)
                continue
            }
            if head == "--" {
                parsingOptions = false
                continue
            }

            if head.hasPrefix("--") {
                let name = String(head.prefix { $0 != "=" })
                let attached = head.contains("=")
                    ? String(head.drop { $0 != "=" }.dropFirst())
                    : nil
                if valueOptions.contains(name) {
                    if let attached {
                        result.options.append((name, attached))
                    } else {
                        let next = rest.first
                        if next != nil { rest = rest.dropFirst() }
                        result.options.append((name, next))
                    }
                } else if attachedValueOptions.contains(name) {
                    result.options.append((name, attached))
                } else if flagOptions.contains(name), attached == nil {
                    result.options.append((name, nil))
                } else {
                    result.unreadableOption = head
                    return result
                }
                continue
            }

            var cluster = head.dropFirst()
            while let flag = cluster.first {
                cluster = cluster.dropFirst()
                let name = "-\(flag)"
                if valueOptions.contains(name) {
                    if cluster.isEmpty {
                        let next = rest.first
                        if next != nil { rest = rest.dropFirst() }
                        result.options.append((name, next))
                    } else {
                        result.options.append((name, String(cluster)))
                        cluster = ""
                    }
                } else if attachedValueOptions.contains(name) {
                    result.options.append((name, cluster.isEmpty ? nil : String(cluster)))
                    cluster = ""
                } else if flagOptions.contains(name) {
                    result.options.append((name, nil))
                } else {
                    result.unreadableOption = head
                    return result
                }
            }
        }
        return result
    }

    // MARK: - Network

    static func network(_ name: String, _ arguments: [String]) -> ShellCommandVerdict {
        let sending: Set = [
            "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "-F", "--form",
            "--form-string", "-T", "--upload-file", "--json", "--post-data", "--post-file",
            "--body-data", "--body-file",
        ]
        let outputs: Set = ["-o", "--output", "--output-document", "-P", "--directory-prefix"]
        var written: [String] = []
        for (index, argument) in arguments.enumerated() {
            let key = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            let next = index + 1 < arguments.count ? arguments[index + 1] : ""
            if sending.contains(key) { return .attention("sends data to a server") }
            // curl clusters short flags: `-sd@body.json` still sends.
            if name == "curl", argument.hasPrefix("-"), !argument.hasPrefix("--"),
               argument.dropFirst().contains(where: { "dFT".contains($0) }) {
                return .attention("sends data to a server")
            }
            var method: String?
            if key == "-X" || key == "--request" || key == "--method" {
                method = argument.contains("=") ? String(argument.drop { $0 != "=" }.dropFirst()) : next
            } else if argument.hasPrefix("-X"), argument.count > 2 {
                method = String(argument.dropFirst(2))
            }
            if let method, !["GET", "HEAD"].contains(method.uppercased()) {
                return .attention("sends a \(method.uppercased()) request")
            }
            if outputs.contains(key) {
                written.append(argument.contains("=") ? String(argument.drop { $0 != "=" }.dropFirst()) : next)
            }
        }
        if !written.isEmpty { return writes(to: written, as: "downloads a file into the project") }
        let host = arguments
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .flatMap { URL(string: $0)?.host }
        return .unknown(host.map { "fetches from \($0)" } ?? "fetches from the network")
    }

    // MARK: - Shells

    /// `bash -lc 'git status'` is read, not trusted: the wrapper is only as
    /// safe as the script inside it.
    static func shell(_ arguments: [String], depth: Int, readsFromPipe: Bool) -> ShellCommandVerdict {
        var rest = arguments[...]
        var script: String?
        while let head = rest.first, head.hasPrefix("-") || head.hasPrefix("+") {
            rest = rest.dropFirst()
            if head == "-o" || head == "+o" {
                rest = rest.dropFirst()
            } else if head.hasPrefix("-"), !head.hasPrefix("--"), head.contains("c") {
                script = rest.first
                break
            }
        }
        if let script {
            guard depth < maximumNesting else {
                return .attention("nests shells too deeply for ORE to read")
            }
            return classify(script, depth: depth + 1)
        }
        guard let file = rest.first else {
            return .attention(readsFromPipe
                ? "runs a script piped from the previous command"
                : "starts an interactive shell")
        }
        return ProjectPaths.isInside(file)
            ? .unknown("runs a project script")
            : .attention("runs a script outside the project")
    }
}
