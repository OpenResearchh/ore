import AppKit
import OreProtocol
import SwiftUI

/// Chips + image previews for composer attachments. User bubbles render the
/// same vocabulary through `TranscriptView` so a sent image doesn't collapse
/// into `@pasted-image.png` text.
struct AttachmentChipStrip: View {
    let attachments: [IndexedAttachment]
    var worktreePath: String
    var onRemove: ((Int) -> Void)?

    struct IndexedAttachment: Identifiable {
        var index: Int
        var attachment: Attachment
        var id: Int { index }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(attachments) { item in
                    AttachmentChip(
                        attachment: item.attachment,
                        worktreePath: worktreePath,
                        onRemove: onRemove.map { action in { action(item.index) } }
                    )
                }
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var worktreePath: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            preview
            Text("@\(attachment.displayName)")
                .lineLimit(1)
                .font(.caption)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(OreTheme.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.isImage, let image = NSImage(contentsOf: attachment.fileURL(worktreePath: worktreePath)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            SourceFileIcon(path: attachment.displayName, size: 16)
        }
    }
}
