# Chat Workspace integration

Ticket #21 supplies the local chat lifecycle in `lib/core/chat/chat_workspace.dart`.
The v1 screen still runs until the v2 UI tickets connect the workspace.

## Ownership and lifecycle

Create one workspace per open Local Data Vault. Opening the workspace performs
launch recovery: persisted generating turns become interrupted, expired chats
are reaped, and the last opened chat is restored. Call `suspend()` when the app
leaves the foreground and `resume()` when it returns. Tab navigation alone must
not call these hooks. Dispose the workspace before closing the vault.

Subscribe to `changes` to refresh UI state. Reads do not emit changes. Use
`newChat`, `openChat`, `history`, `transcript`, and `rename` for history.
Search is a case-insensitive literal match over titles and both sides of every
retained turn. It currently scans local records; it makes no network calls.

## Generation integration

Call `beginTurn` before starting the model. It captures the mode, source scope,
and admitted evidence in one transaction. All selected Knowledge Base sources
must be indexed. A SQLite uniqueness constraint allows one generating turn
globally.

Persist each response snapshot using `saveResponse`. Complete it with an
explicit terminal outcome; use stopped for the Stop action. Suspension and
restart retain partial text with an interrupted outcome. Late output for a
deleted or interrupted turn is rejected. Generation adapters and token-budget
assembly belong to subsequent tickets.

## Context summaries

`context(chatId)` returns four recent turns and a separately persisted summary
of earlier context. This first implementation uses deterministic excerpts:
up to eight older turns, up to 80 Unicode code points per speaker, with speaker
labels, outcomes, and an explicit omission notice. It refreshes when the
summarized-through ordinal advances. It is not a model-generated semantic
summary and may omit details needed by a later question. The conversation
engine must still count tokens and admit context within its actual budget.

The summary is conversation data, never source evidence. It contains no other
chat's state. The displayed transcript remains complete. Truncation invalidates
a summary if it includes any deleted turns.

## Deletion and retention

`deleteChat` hides the chat immediately and persists a five-second Undo
deadline. A local timer permanently deletes it at expiry. Launch/resume also
enforces expired deadlines after process termination. Undo restores the complete
chat only before the deadline.

For retention changes, display `previewRetention`'s affected count, then pass
that same preview to `confirmRetention` after the user accepts it. Previews are
single-use and tied to their workspace. Confirmation removes only previewed
chats whose revision has not changed. It preserves app-lock preferences.
Launch/resume reap whole chats at or beyond 30 or 90 days of inactivity; manual
retention never reaps by age. Active generation and a pending Undo window are
excluded from age-based reaping.

Activity is creation, submitting/updating a response, renaming, changing scope,
truncating, or restoring a chat. Merely reading history or opening a chat does
not reset inactivity.

## Migration and verification

Database schema 2 adds lifecycle columns, persistent current-chat selection, and
the single-generation index. The schema-1 migration runs in one transaction and
validates before committing. This does not migrate or reset the v1 document
database; the existing explicit-reset boundary remains.

Portable tests exercise history isolation, automatic/manual titles, literal
search, truncation, summary refresh, Undo expiry and restart, retention
boundaries and stale previews, partial-response recovery, source capture,
current-chat restoration, and successful/failed schema migration.
