import AppKit
import OreGit
import OreProtocol
import SwiftUI

/// What a changed file looks like when it is not text.
///
/// `git diff` reduces every non-text file to the string "Binary files a/… and
/// b/… differ", and the review pane used to pass that straight through as the
/// word "Binary file". For an icon, a screenshot, or an exported asset — the
/// things an agent most often adds — that is the one case where a reviewer
/// most needs to *see* the result, and the least useful thing to show them.
///
/// This renders the file instead. Images and PDFs get a real preview;
/// anything else at least gets its type and size rather than a dead end.
///
/// The current version is read from the worktree and the previous one — the
/// merge base the review diff compares against — from git. A replaced image
/// shows both side by side, and a deleted one still shows what was removed:
/// "there is nothing left to preview" was true of the worktree and useless to
/// someone deciding whether the deletion was right.
struct BinaryFilePreview: View {
    @Environment(AppModel.self) private var model

    let path: String
    /// The change under review, or nil for a file opened as it is now.
    var status: GitFileChange.Status?
    /// Where a renamed file lived at the base.
    var originalPath: String?
    let workspaceID: WorkspaceID
    let worktreePath: String
    /// Bumped by the git watcher whenever the worktree changes. Part of this
    /// view's task identity, because the interesting case — an agent
    /// regenerating `icon.png` in place — changes the file without changing
    /// its path, and a preview keyed on the path alone kept showing the old
    /// image until the reviewer clicked away and back.
    ///
    /// It moves for a write *anywhere* in the worktree, though, so it only
    /// prompts a look at this file's stamp; the images are re-read when the
    /// stamp says this file changed.
    var generation: UInt64
    /// Review has to work on files that have no lines to attach a comment to,
    /// so the hover chip lives on the preview itself.
    var onComment: () -> Void

    @State private var before: Loaded?
    @State private var after: Loaded?
    @State private var isHovering = false
    /// Which file the images on screen belong to. While it matches, a
    /// revalidation keeps them up: blanking to a spinner collapsed the 420pt
    /// image and regrew it, jumping the scroll under the reader.
    @State private var loadedIdentity: String?
    /// The worktree file's size and modification date when it was last read.
    @State private var loadedStamp: WorktreeFileStamp?

    private var kind: BinaryFileKind { BinaryFileKind(path: path) }

    /// The file and change being shown, without the worktree state.
    private var identity: String {
        "\(worktreePath)|\(path)|\(status?.rawValue ?? "")"
    }

    /// One load per (file, change, worktree state). Also the token a finished
    /// read is checked against before it is allowed to draw.
    private var taskID: String {
        "\(identity)|\(generation)"
    }

    /// The version the header describes: the current file, or the removed one.
    private var primary: Loaded? { after ?? before }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        .task(id: taskID) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(kind.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if let dimensions {
                metadataChip(dimensions)
            }
            if let byteCount = primary?.byteCount {
                metadataChip(
                    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                )
            }

            Spacer(minLength: 0)

            // Mirrors the comment affordance on a diff line: invisible until
            // the pointer is here, so it does not add permanent furniture.
            Button(action: onComment) {
                Image(systemName: "plus.bubble").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Comment on this file")
        }
    }

    /// Pixels, read from the file's own metadata — not the points `NSImage`
    /// reports, which halve every Retina asset and made a 64×64 `@2x` icon
    /// read as 32×32.
    private var dimensions: String? {
        guard let pixelSize = primary?.pixelSize, pixelSize.width > 0 else { return nil }
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    private func metadataChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(OreTheme.subduedFill, in: Capsule())
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loadedIdentity != identity {
            ProgressView().controlSize(.small)
        } else if let old = before?.image, let new = after?.image {
            HStack(alignment: .top, spacing: 16) {
                labeled("Before", old, maxWidth: 360)
                labeled("After", new, maxWidth: 360)
            }
        } else if status == .deleted {
            if let old = before?.image {
                labeled("Deleted on this branch — last version", old, maxWidth: 480)
            } else {
                note("This file was deleted, and its previous version couldn't be read.")
            }
        } else if let image = after?.image {
            framed(image, maxWidth: 480)
        } else if kind.isPreviewable {
            note("Could not read this file for preview.")
        } else {
            note("\(kind.label) files can't be shown inline.")
            Button("Show in Finder", action: showInFinder)
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    private func labeled(_ title: String, _ image: NSImage, maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            framed(image, maxWidth: maxWidth)
        }
    }

    /// A checkerboard, because transparency is the whole point of most of the
    /// icons that land here and a white PNG on a white pane looks identical to
    /// an empty one.
    private func framed(_ image: NSImage, maxWidth: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: maxWidth, maxHeight: 420)
            .background(CheckerboardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OreTheme.hairline)
            )
    }

    /// Selects the file in Finder rather than opening it.
    ///
    /// This used to call `NSWorkspace.open`, which *launches* a file in its
    /// default application: an agent-added `.zip` got extracted into the
    /// worktree, a `.dmg` mounted, and a `.pkg` opened Installer — from a
    /// button on a review pane whose whole job is to look without touching.
    /// The path also goes through `safeFileURL`, so a diff naming
    /// `../../../etc/passwd` reveals nothing.
    private func showInFinder() {
        guard let url = try? AppModel.safeFileURL(root: worktreePath, relativePath: path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    // MARK: - Loading

    private func load() async {
        let token = taskID
        let identity = self.identity
        let root = worktreePath
        let relative = path
        let kind = self.kind

        // Stale-while-revalidate. A different file starts from a spinner; the
        // same file keeps its images up while it is checked.
        let isRevalidating = loadedIdentity == identity
        if !isRevalidating {
            before = nil
            after = nil
            loadedIdentity = nil
            loadedStamp = nil
        }
        let stamp = await Task.detached(priority: .userInitiated) {
            WorktreeFileStamp.read(root: root, relativePath: relative)
        }.value
        // The generation moved for a write somewhere else in the worktree.
        if isRevalidating, stamp == loadedStamp { return }

        // An added file has no past, a deleted one no present, and a file
        // opened outside review only needs how it looks now.
        let wantsCurrent = status != .deleted
        let wantsBase = kind.isPreviewable && status != nil
            && status != .added && status != .untracked

        var current: Loaded?
        if wantsCurrent {
            current = await Task.detached(priority: .userInitiated) {
                Self.read(root: root, relativePath: relative, kind: kind)
            }.value
        }
        var base: Loaded?
        if wantsBase,
           let data = await model.baseFileData(path: originalPath ?? path, in: workspaceID) {
            base = await Task.detached(priority: .userInitiated) {
                Self.decode(data: data, kind: kind)
            }.value
        }

        // A `.task` is cancelled when its id changes, but a detached read is
        // not, so a slow file can still land here after the reviewer has
        // moved on.
        guard !Task.isCancelled, token == taskID else { return }
        after = current
        before = base
        loadedStamp = stamp
        loadedIdentity = identity
    }

    /// `@unchecked`: the image is created inside the read and handed over
    /// once, so nothing else ever touches it concurrently.
    struct Loaded: @unchecked Sendable {
        var image: NSImage?
        var pixelSize: CGSize?
        var byteCount: Int64?
    }

    /// The largest edge a preview is decoded to. The pane draws it at 480pt
    /// at most, so this covers a Retina display with room to spare.
    nonisolated static let thumbnailLimit = 960

    /// Reads size, dimensions and a bounded thumbnail — off the main actor,
    /// and for real.
    ///
    /// `NSImage(contentsOf:)` looked like it moved decoding into the
    /// background but does not: it decodes lazily on first draw, which is
    /// during layout, on the main thread. And a byte cap is not a pixel cap —
    /// a 2 MB single-colour 20000×20000 PNG is about 1.6 GB decoded, which is
    /// a beachball and possibly a jetsam kill. ImageIO decodes once, straight
    /// to the size actually needed, and reports the real pixel dimensions
    /// from the file's metadata without decoding at all.
    nonisolated static func read(
        root: String, relativePath: String, kind: BinaryFileKind
    ) -> Loaded {
        guard let url = try? AppModel.safeFileURL(root: root, relativePath: relativePath),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        else { return Loaded() }
        let byteCount = values.fileSize.map(Int64.init)
        guard kind.isPreviewable else { return Loaded(byteCount: byteCount) }

        // Vectors and PDFs have no pixels to thumbnail and no meaningful
        // source dimensions; AppKit draws them at whatever size it is asked
        // for, so they keep the direct path. Both are small by nature.
        if kind.isVector {
            let image = NSImage(contentsOf: url)
            return Loaded(image: image, pixelSize: image?.size, byteCount: byteCount)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Loaded(byteCount: byteCount)
        }
        return thumbnail(from: source, byteCount: byteCount)
    }

    /// `read`, for bytes that came out of git rather than off the disk.
    nonisolated static func decode(data: Data, kind: BinaryFileKind) -> Loaded {
        let byteCount = Int64(data.count)
        guard kind.isPreviewable else { return Loaded(byteCount: byteCount) }
        if kind.isVector {
            let image = NSImage(data: data)
            return Loaded(image: image, pixelSize: image?.size, byteCount: byteCount)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return Loaded(byteCount: byteCount)
        }
        return thumbnail(from: source, byteCount: byteCount)
    }

    private nonisolated static func thumbnail(
        from source: CGImageSource, byteCount: Int64?
    ) -> Loaded {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelSize = properties.flatMap { properties -> CGSize? in
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return CGSize(width: width, height: height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailLimit,
            // Decode here, in this task, rather than when SwiftUI draws it.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            return Loaded(pixelSize: pixelSize, byteCount: byteCount)
        }
        let image = NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
        return Loaded(image: image, pixelSize: pixelSize ?? image.size, byteCount: byteCount)
    }
}

/// Whether a worktree file changed since it was last read, without reading it.
///
/// The git generation moves for any write in the worktree, so previews that
/// keyed on it reloaded — and reset — whenever an agent touched an unrelated
/// file. Size and modification date answer "did *this* file change" with one
/// `stat`.
struct WorktreeFileStamp: Hashable, Sendable {
    var size: Int?
    var modified: Date?

    /// Nil when the file isn't in the worktree, or the path escapes it.
    nonisolated static func read(root: String, relativePath: String) -> WorktreeFileStamp? {
        guard let url = try? AppModel.safeFileURL(root: root, relativePath: relativePath) else {
            return nil
        }
        return read(url: url)
    }

    nonisolated static func read(url: URL) -> WorktreeFileStamp? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return nil }
        return WorktreeFileStamp(size: values.fileSize, modified: values.contentModificationDate)
    }
}

/// Which non-text files can be shown, and what to call them.
///
/// Separate from `FileVisualIdentity` (which picks a list icon) because the
/// question is different: that one always has an answer, this one is
/// specifically "can AppKit draw this".
struct BinaryFileKind: Sendable {
    let label: String
    let isPreviewable: Bool
    /// Resolution-independent: there is nothing to downsample, and no pixel
    /// dimensions to report. Kept on the direct AppKit path.
    var isVector = false
    /// Recognised as a format that is never text, so there is no source to
    /// open. False for SVG, which is XML, and for anything unrecognised — a
    /// `Makefile` has no extension and is still text.
    var isKnownBinary = true

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "svg": (label, isPreviewable, isVector, isKnownBinary) = ("SVG image", true, true, false)
        case "pdf": (label, isPreviewable, isVector) = ("PDF", true, true)
        // NSImage handles all of these natively, SVG included since macOS 13.
        case "png": (label, isPreviewable) = ("PNG image", true)
        case "jpg", "jpeg": (label, isPreviewable) = ("JPEG image", true)
        case "gif": (label, isPreviewable) = ("GIF image", true)
        case "webp": (label, isPreviewable) = ("WebP image", true)
        case "heic": (label, isPreviewable) = ("HEIC image", true)
        case "tiff", "tif": (label, isPreviewable) = ("TIFF image", true)
        case "bmp": (label, isPreviewable) = ("Bitmap image", true)
        case "icns": (label, isPreviewable) = ("Icon", true)
        case "ico": (label, isPreviewable) = ("Icon", true)
        case "mp4", "mov", "webm": (label, isPreviewable) = ("Video", false)
        case "mp3", "wav", "m4a", "aiff": (label, isPreviewable) = ("Audio", false)
        case "zip", "gz", "tar", "bz2", "7z": (label, isPreviewable) = ("Archive", false)
        case "woff", "woff2", "ttf", "otf": (label, isPreviewable) = ("Font", false)
        case "sqlite", "db": (label, isPreviewable) = ("Database", false)
        default: (label, isPreviewable, isKnownBinary) = ("Binary file", false, false)
        }
    }
}

/// The standard transparency backdrop. Without it a transparent or white
/// asset is indistinguishable from a failed load.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square = 8.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let shade = Color(white: 0.88)
            var row = 0
            var y = 0.0
            while y < size.height {
                var x = row.isMultiple(of: 2) ? 0.0 : square
                while x < size.width {
                    context.fill(
                        Path(CGRect(x: x, y: y, width: square, height: square)),
                        with: .color(shade)
                    )
                    x += square * 2
                }
                y += square
                row += 1
            }
        }
        .opacity(0.55)
    }
}
