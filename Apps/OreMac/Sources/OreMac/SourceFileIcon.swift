import AppKit
import SwiftUI

/// One vocabulary for source-file icons across the tree, tabs, diffs,
/// attachments, quick-open, and agent activity. A file should never look like
/// a generic document in one surface and a language in another.
struct FileVisualIdentity: Hashable {
    enum Tone: Hashable {
        case blue, cyan, green, yellow, orange, red, pink, purple, gray, brown

        var color: Color { Color(nsColor: nsColor) }
        var nsColor: NSColor {
            switch self {
            case .blue: .systemBlue
            case .cyan: .systemCyan
            case .green: .systemGreen
            case .yellow: .systemYellow
            case .orange: .systemOrange
            case .red: .systemRed
            case .pink: .systemPink
            case .purple: .systemPurple
            case .gray: .secondaryLabelColor
            case .brown: .systemBrown
            }
        }
    }

    var glyph: String?
    var symbol: String
    var tone: Tone
    var label: String
    var isDirectory = false

    init(path: String, isDirectory: Bool = false) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        self.isDirectory = isDirectory

        if isDirectory {
            glyph = nil; symbol = "folder.fill"; tone = .blue; label = "Folder"
            return
        }

        switch (name, ext) {
        case (_, "swift"), ("package.swift", _):
            glyph = nil; symbol = "swift"; tone = .orange; label = "Swift"
        case (_, "tsx"), (_, "ts"):
            glyph = "TS"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .blue; label = "TypeScript"
        case (_, "jsx"), (_, "js"), (_, "mjs"), (_, "cjs"):
            glyph = "JS"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .yellow; label = "JavaScript"
        case (_, "py"), (_, "pyi"):
            glyph = "Py"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .blue; label = "Python"
        case (_, "rb"):
            glyph = "◆"; symbol = "diamond.fill"; tone = .red; label = "Ruby"
        case (_, "rs"):
            glyph = "Rs"; symbol = "gearshape.fill"; tone = .orange; label = "Rust"
        case (_, "go"):
            glyph = "Go"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .cyan; label = "Go"
        case (_, "java"):
            glyph = nil; symbol = "cup.and.saucer.fill"; tone = .orange; label = "Java"
        case (_, "kt"), (_, "kts"):
            glyph = "K"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .purple; label = "Kotlin"
        case (_, "c"), (_, "h"):
            glyph = "C"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .blue; label = "C"
        case (_, "cc"), (_, "cpp"), (_, "cxx"), (_, "hpp"):
            glyph = "C+"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .blue; label = "C++"
        case (_, "cs"):
            glyph = "C#"; symbol = "number"; tone = .purple; label = "C sharp"
        case (_, "php"):
            glyph = "php"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .purple; label = "PHP"
        case (_, "dart"):
            glyph = "D"; symbol = "diamond.fill"; tone = .cyan; label = "Dart"
        case (_, "ex"), (_, "exs"):
            glyph = "Ex"; symbol = "drop.fill"; tone = .purple; label = "Elixir"
        case (_, "scala"):
            glyph = "S"; symbol = "line.3.horizontal"; tone = .red; label = "Scala"
        case (_, "lua"):
            glyph = "Lua"; symbol = "moon.stars.fill"; tone = .blue; label = "Lua"
        case (_, "r"):
            glyph = "R"; symbol = "chart.xyaxis.line"; tone = .blue; label = "R"
        case (_, "html"), (_, "htm"):
            glyph = "<>"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .orange; label = "HTML"
        case (_, "css"):
            glyph = "#"; symbol = "number"; tone = .blue; label = "CSS"
        case (_, "scss"), (_, "sass"):
            glyph = "S"; symbol = "number"; tone = .pink; label = "Sass"
        case (_, "vue"):
            glyph = "V"; symbol = "v.square.fill"; tone = .green; label = "Vue"
        case (_, "svelte"):
            glyph = "S"; symbol = "s.square.fill"; tone = .red; label = "Svelte"
        case (_, "json"), (_, "jsonc"), ("package-lock.json", _):
            glyph = "{}"; symbol = "curlybraces"; tone = .yellow; label = "JSON"
        case (_, "yaml"), (_, "yml"):
            glyph = "Y"; symbol = "list.bullet.rectangle"; tone = .red; label = "YAML"
        case (_, "toml"):
            glyph = "T"; symbol = "slider.horizontal.3"; tone = .brown; label = "TOML"
        case (_, "xml"):
            glyph = "<>"; symbol = "chevron.left.forwardslash.chevron.right"; tone = .orange; label = "XML"
        case (_, "md"), (_, "markdown"), (_, "mdx"):
            glyph = "M↓"; symbol = "text.document.fill"; tone = .blue; label = "Markdown"
        case (_, "sh"), (_, "bash"), (_, "zsh"), (_, "fish"), ("makefile", _):
            glyph = ">_"; symbol = "terminal.fill"; tone = .green; label = "Shell script"
        case (_, "sql"):
            glyph = nil; symbol = "cylinder.fill"; tone = .blue; label = "SQL"
        case (_, "graphql"), (_, "gql"):
            glyph = "◇"; symbol = "point.3.connected.trianglepath.dotted"; tone = .pink; label = "GraphQL"
        case ("dockerfile", _), ("compose.yml", _), ("compose.yaml", _), ("docker-compose.yml", _):
            glyph = nil; symbol = "shippingbox.fill"; tone = .blue; label = "Docker"
        case (let file, _) where file.hasPrefix(".git"):
            glyph = nil; symbol = "point.3.connected.trianglepath.dotted"; tone = .orange; label = "Git configuration"
        case (let file, _) where file.hasPrefix(".env"):
            glyph = nil; symbol = "key.fill"; tone = .yellow; label = "Environment file"
        case (_, "plist"):
            glyph = nil; symbol = "list.bullet.rectangle.fill"; tone = .gray; label = "Property list"
        case (_, "lock"):
            glyph = nil; symbol = "lock.fill"; tone = .gray; label = "Lock file"
        case (_, "png"), (_, "jpg"), (_, "jpeg"), (_, "gif"), (_, "webp"), (_, "heic"), (_, "svg"):
            glyph = nil; symbol = "photo.fill"; tone = .purple; label = "Image"
        case (_, "pdf"):
            glyph = "PDF"; symbol = "doc.richtext.fill"; tone = .red; label = "PDF"
        case (_, "zip"), (_, "gz"), (_, "tar"), (_, "bz2"), (_, "7z"):
            glyph = nil; symbol = "archivebox.fill"; tone = .brown; label = "Archive"
        case (_, "txt"):
            glyph = nil; symbol = "doc.plaintext.fill"; tone = .gray; label = "Text file"
        default:
            glyph = nil; symbol = "doc.fill"; tone = .gray; label = "File"
        }
    }

    @MainActor
    func appKitImage(size: CGFloat = 16) -> NSImage {
        if glyph == nil,
           let source = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            let configured = source.withSymbolConfiguration(.init(pointSize: size * 0.78, weight: .medium)) ?? source
            configured.isTemplate = true
            return configured
        }

        let canvas = NSSize(width: size, height: size)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: size * 0.24, yRadius: size * 0.24)
            self.tone.nsColor.withAlphaComponent(0.17).setFill()
            background.fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = self.glyph ?? ""
            let fontSize = text.count >= 3 ? size * 0.38 : size * 0.48
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: self.tone.nsColor,
                .paragraphStyle: paragraph,
            ]
            let measured = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                in: NSRect(x: 0, y: (size - measured.height) / 2 - 0.5, width: size, height: measured.height),
                withAttributes: attributes
            )
            return true
        }
        image.accessibilityDescription = label
        return image
    }
}

struct SourceFileIcon: View {
    let identity: FileVisualIdentity
    var size: CGFloat

    init(path: String, isDirectory: Bool = false, size: CGFloat = 18) {
        identity = FileVisualIdentity(path: path, isDirectory: isDirectory)
        self.size = size
    }

    var body: some View {
        Group {
            if identity.isDirectory {
                Image(systemName: identity.symbol)
                    .resizable().scaledToFit()
                    .foregroundStyle(identity.tone.color)
                    .padding(1)
            } else if let glyph = identity.glyph {
                Text(glyph)
                    .font(.system(size: glyph.count >= 3 ? size * 0.36 : size * 0.45, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(identity.tone.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(identity.tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.24))
            } else {
                Image(systemName: identity.symbol)
                    .resizable().scaledToFit()
                    .foregroundStyle(identity.tone.color)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(identity.label)
    }
}
