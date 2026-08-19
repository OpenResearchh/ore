import Foundation
import GRDB
import OreProtocol

/// The database schema, as an ordered list of migrations.
///
/// GRDB over SwiftData for three reasons that all show up here: migrations are
/// explicit and versioned, FTS5 gives real transcript search without a second
/// index to keep in sync, and none of it is Apple-only — the same store compiles
/// and runs on Linux, which is what keeps a hosted ORE possible.
public enum OreSchema {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.workspaces") { db in
            try db.create(table: "repository") { table in
                table.primaryKey("path", .text)
                table.column("name", .text).notNull()
                table.column("defaultBranch", .text).notNull()
                table.column("addedAt", .datetime).notNull()
            }

            try db.create(table: "workspace") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("repositoryPath", .text)
                    .notNull()
                    .references("repository", onDelete: .cascade)
                table.column("worktreePath", .text).notNull()
                table.column("branch", .text).notNull()
                table.column("baseBranch", .text).notNull()
                // A workspace stacked on another. Nullified rather than
                // cascaded: deleting the parent must not delete work that was
                // built on top of it.
                table.column("stackedOnWorkspaceID", .text)
                    .references("workspace", onDelete: .setNull)
                table.column("harness", .text).notNull()
                table.column("model", .text)
                table.column("permissionMode", .text).notNull()
                table.column("isPinned", .boolean).notNull().defaults(to: false)
                table.column("isArchived", .boolean).notNull().defaults(to: false)
                table.column("archivedStateCommit", .text)
                table.column("hasUnread", .boolean).notNull().defaults(to: false)
                table.column("sortIndex", .integer).notNull().defaults(to: 0)
                table.column("createdAt", .datetime).notNull()
                table.column("lastActivityAt", .datetime)
            }
            try db.create(
                index: "workspace_on_repository",
                on: "workspace",
                columns: ["repositoryPath", "isArchived"]
            )
        }

        migrator.registerMigration("v1.sessions") { db in
            try db.create(table: "session") { table in
                table.primaryKey("id", .text)
                table.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                // The id the CLI owns. Changes on fork, which is how a
                // checkpoint revert branches the conversation.
                table.column("providerSessionID", .text)
                table.column("harness", .text).notNull()
                table.column("model", .text)
                table.column("harnessVersion", .text)
                table.column("title", .text)
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime)
            }
            try db.create(index: "session_on_workspace", on: "session", columns: ["workspaceID"])
        }

        migrator.registerMigration("v1.transcript") { db in
            try db.create(table: "turn") { table in
                table.primaryKey("id", .text)
                table.column("sessionID", .text)
                    .notNull()
                    .references("session", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                table.column("prompt", .text)
                table.column("outcome", .text)
                table.column("summary", .text)
                table.column("inputTokens", .integer).notNull().defaults(to: 0)
                table.column("outputTokens", .integer).notNull().defaults(to: 0)
                table.column("cacheReadTokens", .integer).notNull().defaults(to: 0)
                table.column("cacheCreationTokens", .integer).notNull().defaults(to: 0)
                table.column("contextWindow", .integer)
                // Checkpoint taken before this turn ran, so reverting *to* a
                // turn means restoring the state it started from.
                table.column("checkpointCommit", .text)
                table.column("checkpointProviderSessionID", .text)
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime)
            }
            try db.create(
                index: "turn_on_session",
                on: "turn",
                columns: ["sessionID", "ordinal"],
                options: .unique
            )

            try db.create(table: "block") { table in
                table.primaryKey("id", .text)
                table.column("turnID", .text)
                    .notNull()
                    .references("turn", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                // text | thinking | toolCall | toolResult | plan | permission | question
                table.column("kind", .text).notNull()
                table.column("text", .text).notNull().defaults(to: "")
                table.column("toolName", .text)
                table.column("toolCallID", .text)
                table.column("displayName", .text)
                table.column("payload", .text)
                table.column("isError", .boolean).notNull().defaults(to: false)
                table.column("parentToolCallID", .text)
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "block_on_turn", on: "block", columns: ["turnID", "ordinal"])
            try db.create(index: "block_on_tool_call", on: "block", columns: ["toolCallID"])
        }

        migrator.registerMigration("v1.search") { db in
            // FTS5 over the transcript. `content=` makes it an external-content
            // index: the text lives once, in `block`, and the index only holds
            // the terms. Triggers keep the two in step, which is the part a
            // hand-rolled search would eventually get wrong.
            try db.create(virtualTable: "blockSearch", using: FTS5()) { table in
                table.synchronize(withTable: "block")
                table.column("text")
                table.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        migrator.registerMigration("v1.review") { db in
            try db.create(table: "diffComment") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                table.column("filePath", .text).notNull()
                table.column("startLine", .integer).notNull()
                table.column("endLine", .integer).notNull()
                table.column("body", .text).notNull()
                table.column("context", .text)
                // Comments are drafted, then sent to the agent as a batch —
                // reviewing is a pass over the diff, not one message per note.
                table.column("isSent", .boolean).notNull().defaults(to: false)
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "diffComment_on_workspace",
                on: "diffComment",
                columns: ["workspaceID", "isSent"]
            )

            try db.create(table: "viewedFile") { table in
                table.primaryKey(["workspaceID", "filePath"])
                table.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                table.column("filePath", .text).notNull()
                // The content hash the user marked as viewed. Storing the hash
                // rather than a flag means a file the agent touches again
                // correctly stops being "viewed".
                table.column("contentHash", .text).notNull()
                table.column("viewedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v1.queue") { db in
            try db.create(table: "queuedMessage") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("attachmentPaths", .text).notNull().defaults(to: "[]")
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "queuedMessage_on_workspace",
                on: "queuedMessage",
                columns: ["workspaceID", "id"]
            )
        }

        migrator.registerMigration("v2.chats") { db in
            try db.create(table: "chat") { table in
                table.primaryKey("id", .text)
                table.column("workspaceID", .text)
                    .notNull()
                    .references("workspace", onDelete: .cascade)
                table.column("title", .text).notNull()
                table.column("harness", .text).notNull()
                table.column("model", .text)
                table.column("permissionMode", .text).notNull()
                table.column("draftText", .text).notNull().defaults(to: "")
                table.column("hasUnread", .boolean).notNull().defaults(to: false)
                table.column("isClosed", .boolean).notNull().defaults(to: false)
                table.column("sortIndex", .integer).notNull().defaults(to: 0)
                table.column("createdAt", .datetime).notNull()
                table.column("lastActivityAt", .datetime)
            }
            try db.create(
                index: "chat_on_workspace",
                on: "chat",
                columns: ["workspaceID", "isClosed", "sortIndex"]
            )

            try db.create(table: "chatTransition") { table in
                table.primaryKey("id", .text)
                table.column("chatID", .text)
                    .notNull()
                    .references("chat", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("fromHarness", .text)
                table.column("toHarness", .text)
                table.column("fromModel", .text)
                table.column("toModel", .text)
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "chatTransition_on_chat",
                on: "chatTransition",
                columns: ["chatID", "createdAt"]
            )

            // The workspace id is a stable default-chat id. This folds every
            // pre-tabs database into the new hierarchy without splitting its
            // transcript or queue.
            try db.execute(sql: """
                INSERT INTO chat (
                    id, workspaceID, title, harness, model, permissionMode,
                    draftText, hasUnread, isClosed, sortIndex, createdAt, lastActivityAt
                )
                SELECT
                    id, id, COALESCE(name, 'Chat'), harness, model, permissionMode,
                    '', hasUnread, 0, 0, createdAt, lastActivityAt
                FROM workspace
                """)

            try db.alter(table: "session") { table in
                table.add(column: "chatID", .text).references("chat", onDelete: .cascade)
            }
            try db.execute(sql: "UPDATE session SET chatID = workspaceID WHERE chatID IS NULL")
            try db.create(index: "session_on_chat", on: "session", columns: ["chatID", "startedAt"])

            try db.alter(table: "queuedMessage") { table in
                table.add(column: "chatID", .text).references("chat", onDelete: .cascade)
            }
            try db.execute(sql: "UPDATE queuedMessage SET chatID = workspaceID WHERE chatID IS NULL")
            try db.create(index: "queuedMessage_on_chat", on: "queuedMessage", columns: ["chatID", "id"])
        }

        migrator.registerMigration("v3.queueServiceTier") { db in
            // A queued turn must preserve the processing tier selected when it
            // was composed. Otherwise a queued Fast turn silently falls back
            // to Standard after an app restart.
            try db.alter(table: "queuedMessage") { table in
                table.add(column: "serviceTier", .text)
            }
        }

        migrator.registerMigration("v4.promptAttachments") { db in
            // User bubbles need the same chips and image previews as the
            // composer. The prompt text only holds @-tokens; the files those
            // tokens refer to live here so a reload can still render them.
            try db.alter(table: "turn") { table in
                table.add(column: "promptAttachments", .text).notNull().defaults(to: "[]")
            }
        }

        // Two branches both reached for "v4" and both shipped. The duplicated
        // prefix is left alone on purpose: a migration's name is its identity,
        // so renaming either one would make databases that already ran it try
        // to run it again and fail on the existing column.
        migrator.registerMigration("v4.userNamed") { db in
            // A name/title the user typed must survive the first turn's
            // auto-titling. Without a persisted flag, a manual rename made
            // before any activity looked identical to an auto-assigned
            // placeholder and was overwritten by the prompt-derived title.
            try db.alter(table: "workspace") { table in
                table.add(column: "isNameUserSet", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "chat") { table in
                table.add(column: "isTitleUserSet", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5.archiveMetadata") { db in
            // The archived browser answers "when did I park this, and what did
            // it give back?" — the worktree's size at archive time is the disk
            // space reclaimed, and it can't be recomputed once the checkout is
            // gone.
            try db.alter(table: "workspace") { table in
                table.add(column: "archivedAt", .datetime)
                table.add(column: "archivedDiskBytes", .integer)
            }
        }

        migrator.registerMigration("v6.workspaceKind") { db in
            // The product-owned assistant workspace lives in the same table as
            // real workspaces — same engine, same transcript — and is told
            // apart by kind, so every existing query stays one query.
            try db.alter(table: "workspace") { table in
                table.add(column: "kind", .text).notNull().defaults(to: "standard")
            }
        }

        migrator.registerMigration("v7.assistantActions") { db in
            // Every action the assistant takes on the user's behalf, with how
            // it was authorized. The Actions tab renders this; trust in an
            // agent that acts for you is built on being able to check.
            try db.create(table: "assistantAction") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("tool", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("arguments", .text).notNull().defaults(to: "{}")
                // auto | grantedTask | grantedAlways | allowedOnce |
                // allowedTask | allowedAlways | denied | timedOut | failed
                table.column("decision", .text).notNull()
                table.column("workspaceID", .text)
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "assistantAction_on_createdAt",
                on: "assistantAction",
                columns: ["createdAt"]
            )

            // "Always allow" grants. One row per action class the user has
            // permanently granted; deleting the row revokes it.
            try db.create(table: "assistantGrant") { table in
                table.primaryKey("actionClass", .text)
                table.column("createdAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
