# General chat engine integration

Issue #22 adds `GeneralChatEngine`, used alongside the app-lifetime
`ChatWorkspace`. It does not switch the visible v1 screen to the v2 Chat tab;
that wiring belongs to #25. No existing document data is reset.

## Composition and lifecycle

Create one `AppleFoundationModels` adapter and pass it as both `backend` and
`contextProbe` when constructing `GeneralChatEngine`. Supply a `ModelSnapshot`
identifying the local runtime/build; the engine adds `general-v1` prompt metadata.
The engine has no knowledge repository or retrieval dependency.

- `send(chatId:, text:)` atomically admits a General turn, then checks model
  availability, composes/measures the prompt and streams cumulative snapshots.
- Observe `workspace.changes` and read `workspace.transcript(chatId)` to render
  persisted snapshots in place. Use the immutable turn mode and `answerLabel`
  (`General answer`); General turns have no source scope, evidence or citations.
- The returned `GeneralTurnResult` contains the persisted terminal turn and
  `earlierContextSummarized`. Failed turns retain a typed `TurnFailure`, not a
  native error string or an invented assistant response.
- Busy sends fail immediately; nothing is queued. The vault also prohibits a
  second generating turn across chats/controllers, and the native plugin rejects
  overlapping generation calls.
- Await `stop()` before starting another generation or deleting active content.
  It cancels the native subscription even if no snapshot has arrived, then
  persists `stopped` with any partial response.
- Route actual app backgrounding to `engine.suspend()`, not directly to the
  workspace and not on tab changes. Route launch/resume to `engine.resume()`.
  The native plugin independently cancels on iOS background notification and
  emits interruption rather than completion. Launch recovery handles process
  death using the already-persisted generating turn.
- Dispose the engine before the workspace, then close the vault. Stop before
  destructive chat operations; deleting a turn invalidates subsequent writes.

## Context and regeneration

The JSON prompt contains only this chat's separate summary, four recent turns
(including explicit terminal outcome labels), and the current user message.
No shared native model session survives between turns. Exact native token counts
must fit the entire composed prompt plus instructions, 512 output tokens, and
128 framing tokens. An oversized prompt returns `contextOverflow`; it is not
silently truncated. The bounded summary remains extractive as established in
#21, not a semantic model-generated summary.

`regenerate(chatId:, turnId:)` appends a new attempt using the original General
question and context strictly before that turn. It does not delete or overwrite
the original answer or later turns, and it does not change the chat's currently
selected mode/sources. Knowledge Base regeneration is not handled by this engine.

## Native behavior and persistence

The bridge explicitly selects `general` or `knowledge-base`. Older calls without
a mode retain the frozen `guardrail-v1` document transformation behavior.
General generation uses Apple's default model guardrails and separate
instructions. It requests useful general information and concise contextual
caution for legal, medical and financial topics; it cannot guarantee that the
platform model will never refuse. Platform refusal remains a typed failure.
Dart tests verify the measured instruction string exactly matches Swift.

Vault schema 3 adds a nullable failure reason without deleting existing rows.
Schema 1 and 2 upgrades are transactional. Device ineligibility, disabled Apple
Intelligence and model-not-ready remain distinguishable after reopening; the
availability API can be queried again before retrying. Stream failure, context
overflow and guardrail failures retain partial text without marking it complete.

## Verification

Portable scenarios cover chat isolation, summary context, immutable General
provenance, synchronous busy rejection, silent Stop, preflight Stop, suspension,
regeneration after mode changes, availability recovery, measured context overflow,
stream errors, and schema migration/reopen. Method-channel tests cover explicit
mode routing, unrelated-event isolation, cancellation ordering, interrupted
events, premature event-channel closure, and instruction parity.

`RunnerTests` exercises General/Knowledge Base routing, streamed errors, native
Stop with no output, overlapping native requests, background interruption, and
the frozen document instructions using deterministic runtimes. Real model answer
quality, including nuanced professional-topic responses, remains an eligible
physical-iPhone test after #25 exposes the v2 Chat UI. The file-protection test
requires a physical device and is intentionally skipped by the simulator.
