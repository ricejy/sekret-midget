# Multi-source grounded chat integration

Issue #24 extends the General controller into one app-lifetime `ChatEngine`.
The visible v1 screen is unchanged; #25 wires this module into the v2 Chat tab.
The existing guardrail-v1 document path remains separate and unchanged.

## Composition

Create one `AppleFoundationModels` adapter and pass it as `backend`,
`groundedBackend`, and `contextProbe`. Supply the app-lifetime `ChatWorkspace`,
`KnowledgeBase`, and local runtime `ModelSnapshot`. The engine stamps each turn
with the actual prompt version (`general-v1` or `grounded-chat-v1`). General-only
composition may omit the Knowledge Base dependencies and never calls retrieval.

Both modes use the same synchronous busy reservation, persisted lifecycle,
availability checks, Stop, suspension, and native cancellation. Nothing queues.
See [General integration](v2-general-chat-integration.md) for lifecycle wiring.

## Scope, retrieval, and prompt admission

- `workspace.changeScope` remembers the chat's mode and selected sources.
  `engine.send` captures their identifiers and titles before retrieval starts.
  Every selected source must still be indexed. Changes to the current selection
  affect later turns only; changes to a source title do not rewrite old turns.
- Every grounded turn embeds a fresh query consisting of the current message
  and up to two preceding user questions, for follow-up referents. Earlier
  assistant text never enters the retrieval query or the evidence collection.
- `KnowledgeBase.retrieveAcross` checks the entire selected scope before and
  after asynchronous retrieval work. It ranks dense candidates globally,
  interleaves per-source lexical ranks, and fuses them using the shared RRF
  implementation. Only passages from the captured scope are eligible.
- The engine measures the entire composed JSON with the native tokenizer:
  instructions, separate conversation summary/recent turns, current question,
  and whole evidence passages. It admits at most four passages, reserving 512
  output tokens and 128 framing tokens. It never silently truncates a passage.
  If context or the smallest eligible passage cannot fit, the turn fails with
  `contextOverflow` instead of pretending there is no evidence.
- Before generating, `workspace.captureEvidence` seals passage text, frozen
  source title, page, section, and source cards in one vault transaction. This
  rechecks source readiness and passage membership. A changed/deleted/reindexed
  input cannot cause a mixed snapshot. The seal cannot be rewritten, and a
  failed capture rolls back all partial inserts.

The prompt explicitly separates `conversation_context`, `current_user_message`,
and `current_evidence`. Only the last field supplies facts. No native model
conversation session or cross-chat memory survives between turns.

## Outcomes and source cards

No retrieved evidence, the model's fixed abstention, or a rejected output gives
the exact response: `I couldn’t find enough evidence in this document.` The turn
is `insufficientEvidence`, never silently rerouted to General. Model readiness,
retrieval failure, source invalidation, context overflow, and interruption remain
distinct from that outcome.

Grounded output has a conservative evidence-presence screen: unexpected numeric
literals, numeric citation markers, or insufficient content-word overlap are
rejected. This is **not semantic entailment verification**: negation, swapped
source attribution, and other subtly incorrect statements can still pass, while
valid paraphrases or calculations can be rejected. Native grounding instructions
and later real-model acceptance tests remain necessary. Do not present this
screen as a guarantee of factual correctness.

The app owns source cards; the model does not create inline markers. Each card
describes an admitted passage, not an independently verified claim-to-passage
mapping. Render cards with their turn's outcome and expose the captured passage
for inspection. Unsupported partial snapshots are not persisted; Stop retains
only the latest accepted partial snapshot and labels it stopped/interrupted.

Deleting a source preserves the original chat text and provenance. Existing
snapshot readers dynamically mark it `Source deleted`. The current catalogue
and live preview may no longer be available, but the historical excerpt remains.

## Regeneration and persistence

`engine.regenerate` appends a new attempt with the original question, mode, and
source IDs, retrieving fresh evidence using context strictly before the original
turn. It preserves the original and later turns and leaves current selection
unchanged. Missing or non-indexed original sources block regeneration; they are
not silently dropped or replaced. Fresh retrieval may differ after reindexing,
but every previous turn keeps its own immutable evidence.

Vault schema 5 adds a one-time evidence-capture flag. Existing schema-4 turns
migrate as already sealed; earlier supported versions upgrade transactionally.
No chat or document reset is required. Turns admitted for retrieval but not yet
generating output are still persisted as generating and use the existing crash
recovery path.

## Verification

`test/grounded_chat_engine_test.dart` exercises real SQLite and Knowledge Base
retrieval with fictional sources and deterministic embeddings/model snapshots.
It covers multiple sources, excluded documents, one-time capture and rollback,
scope/title races, follow-ups, abstention, budgets, regeneration, deletion,
source invalidation, retrieval errors, shared busy/Stop, interruption, and
schema-4 migration/reopen. The integration entry point reuses these scenarios
on the physical iPhone's Dart/native-SQLite runtime:

```sh
flutter test integration_test/grounded_chat_test.dart -d <usb-device-id> --no-uninstall
```

Keep the phone unlocked and connected by USB. The test uses isolated in-memory
and temporary databases, not the user's production vault. `--no-uninstall`
prevents Flutter's default post-test app removal. It installs a test build, so
relaunch a normal development build afterwards when testing the visible app.

Portable adapter tests verify exact Dart/Swift instruction parity and explicit
`grounded-chat` channel routing. Native `RunnerTests` exercises all three modes
and the existing cancellation, backgrounding, and protection regressions with
deterministic runtimes. These checks do not substitute for real Apple-model
quality testing through the v2 UI in #25/#29.
