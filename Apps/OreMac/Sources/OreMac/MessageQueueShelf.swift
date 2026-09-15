import OrePersistence
import SwiftUI

/// Shares the composer's surface so pending prompts read as part of the input.
struct MessageQueueShelf: View {
    let messages: [QueuedMessageRecord]
    let onSave: (QueuedMessageRecord, String) async throws -> Void
    let onDelete: (QueuedMessageRecord) async throws -> Void
    let onMove: (QueuedMessageRecord, Int) async throws -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var editingID: Int64?
    @State private var editText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .foregroundStyle(.secondary)
                    Text("\(messages.count) follow-up\(messages.count == 1 ? "" : "s") queued")
                        .fontWeight(.medium)
                    if !isExpanded, let first = messages.first {
                        Text(first.text.isEmpty ? "Attachment" : first.text)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help(isExpanded ? "Collapse queued follow-ups" : "Edit and reorder queued follow-ups")

            if isExpanded {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, record in
                            queueRow(record, index: index)
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(messages.count) * 66 + (editingID == nil ? 0 : 110), 220))
                .scrollBounceBehavior(.basedOnSize)
                Text("Sent in this order as the agent becomes ready.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: messages.map(\.id)) { _, ids in
            if let editingID, !ids.contains(editingID) {
                self.editingID = nil
                editText = ""
            }
        }
    }

    private func queueRow(_ record: QueuedMessageRecord, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.text.isEmpty ? "Attachment" : record.text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !record.paths.isEmpty {
                        Label("\(record.paths.count) attachment\(record.paths.count == 1 ? "" : "s")", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 2) {
                    rowButton("Move earlier", icon: "arrow.up", disabled: index == 0 || editingID != nil) {
                        perform { try await onMove(record, -1) }
                    }
                    rowButton("Move later", icon: "arrow.down", disabled: index == messages.count - 1 || editingID != nil) {
                        perform { try await onMove(record, 1) }
                    }
                    rowButton("Edit follow-up", icon: "pencil", disabled: editingID != nil) {
                        editingID = record.id
                        editText = record.text
                    }
                    rowButton("Remove follow-up", icon: "trash", disabled: editingID != nil) {
                        perform { try await onDelete(record) }
                    }
                }
            }
            if editingID == record.id {
                TextField("Queued follow-up", text: $editText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(OreTheme.subduedFill, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isWorking)
                HStack {
                    Spacer()
                    Button("Cancel") { editingID = nil }
                    Button("Save") {
                        let text = editText
                        perform {
                            try await onSave(record, text)
                            editingID = nil
                        }
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.paths.isEmpty)
                }
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
        .padding(8)
        .background(OreTheme.subduedFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func rowButton(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(disabled || isWorking)
        .accessibilityLabel(title)
        .help(title)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do { try await operation() }
            catch { errorMessage = "Couldn’t update the queue. Please try again." }
        }
    }
}
