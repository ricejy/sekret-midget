# Sekret v2 architecture direction

- **Status:** Proposed implementation shape derived from the confirmed product scope
- **Purpose:** Define deep modules and their seams before tickets commit to file-level structure

## Design pressure

V1 proves local ingestion, retrieval, generation, citations, and deletion, but its UI coordinates a single selected document and a single question-oriented workflow. V2 adds durable chats, two answer modes, multiple selected sources, context summaries, immutable provenance, resumable knowledge processing, preview, retention, and app locking. Those behaviors should not be distributed across screens.

The design target is a small set of deep modules whose interfaces expose user-observable operations while hiding SQLite transactions, prompt assembly, retrieval coordination, summary maintenance, native capability calls, and lifecycle recovery.

## Proposed modules

### Chat Workspace

The Chat Workspace owns chat lifecycle, history presentation data, selected sources, retention, reaping, and destructive chat operations.

Its interface should let callers:

- Observe the chat list and one opened chat.
- Create, open, rename, search, and delete a chat.
- Change the opened chat's mode and selected sources.
- Submit, stop, and regenerate a turn.
- Delete a turn and everything after it.

The implementation hides title derivation, persistence, Undo staging, one-generation-at-a-time enforcement, source readiness checks, context-summary refresh, and interruption recovery. UI callers receive state and domain outcomes rather than coordinating these steps.

This module should be tested at its interface with an in-memory SQLite database and fake native adapters. SQLite is local-substitutable, so a public repository port would add indirection without a second meaningful adapter.

### Conversation Engine

The Conversation Engine is internal to the Chat Workspace. Its narrow entry point accepts a turn request containing the chat context, mode, and immutable source scope, and produces a stream of turn events ending in a recorded outcome.

The implementation hides:

- Follow-up question interpretation.
- Prompt and context-budget assembly.
- Fresh retrieval for Knowledge Base mode.
- The prohibition on using earlier assistant claims as evidence.
- General versus grounded instructions.
- Exact insufficient-evidence behavior.
- Streaming generation and interruption.
- Citation construction.
- Context-summary maintenance.
- Provenance capture.

This is a deep internal module: tests should exercise full turn outcomes through its interface rather than separately asserting prompt fragments, ranking orchestration, or persistence calls.

### Knowledge Base

The Knowledge Base owns catalogue queries, ingestion, processing state, duplicate detection, local content search, preview descriptors, citation resolution, re-indexing, retry, cancellation, and deletion.

Its interface should let callers:

- Observe and search catalogue entries.
- Begin an import from a supported local source.
- Resume, retry, cancel, rename, re-index, or delete a knowledge item.
- Resolve selected source IDs into readiness information.
- Retrieve ranked evidence across an immutable source scope.
- Open a preview at a knowledge location.

The implementation hides extraction, OCR, chunking, embedding, indexing transactions, partial-work checkpoints, FTS queries, vector scans, reciprocal-rank fusion, and cascade cleanup. Partial indexes never cross the interface as searchable evidence.

The current `DocumentLibrary` is the natural starting seam, but it should be deepened rather than wrapped with chat-specific pass-through modules. Tests use in-memory SQLite and fake native adapters.

### Local Data Vault

The Local Data Vault is an internal implementation shared by Chat Workspace and Knowledge Base. It owns the single local database, schema version, transactions, file-protection setup, storage accounting, and the one-time v1 reset path.

It is not a broad UI-facing data interface. Higher modules ask it to perform cohesive domain operations so SQL knowledge remains local. V2 starts with a fresh schema on the owner's development device; later schema revisions require transactional migrations.

### App Protection

App Protection owns foreground lock state, authentication, lock delay, app-switcher obscuring, and authorization for erase-all.

Its interface exposes current protection state and a small number of user intents such as unlock, change policy, and authorize destructive erasure. Native authentication and an in-memory test adapter make this a real seam with two adapters.

## Existing native seams

The existing `LlmBackend`, `Embedder`, `OcrEngine`, and `TokenCounter` seams remain justified because each has an Apple production adapter and a deterministic fake adapter. They are local capability seams, not placeholders for cloud providers. V2 must not add provider, account, billing, or network concepts to their interfaces.

PDF extraction, page rasterization, and file/image selection remain platform adapters where production and test behavior genuinely vary.

## Core records

The implementation will need durable records equivalent to:

- Chat: identity, title, timestamps, current mode, and selected sources.
- Turn: ordered user input and assistant outcome.
- Turn provenance: immutable mode, source scope, retrieved evidence references, citations, and diagnostic model metadata.
- Context summary: summarized-through turn and local summary text.
- Knowledge item: source identity, metadata, processing state, and duplicate fingerprint.
- Processing checkpoint: resumable progress that is not yet queryable.
- Evidence passage: ranked chunk plus source location.
- Retention policy and app-lock preference.

These names follow [CONTEXT.md](../../CONTEXT.md). Storage tables may differ; table structure is implementation, not the domain model.

## Invariants

- General mode never reads Knowledge Base evidence.
- Knowledge Base mode never silently falls back to model knowledge.
- A turn's provenance never changes after the turn begins.
- Changing selected sources affects only future turns.
- Every Knowledge Base turn performs fresh retrieval.
- Assistant output is never promoted into evidence.
- Only indexed knowledge items may produce evidence.
- Partial processing state is never queryable.
- One generation may be active globally.
- The full chat remains visible even after a context summary is created.
- Reaping deletes complete chats.
- Deleting a knowledge item retains chat text and invalidates source navigation.
- Erase All removes all user-content-bearing local records.

## State models

### Turn generation

`idle → generating → completed | stopped | interrupted | failed`

Only `completed` produces a completed answer. Stopped and interrupted outcomes remain visible and may be regenerated. A new generation cannot begin while any turn is generating.

### Knowledge processing

`processing → indexed | paused | failed`

Paused and failed work may return to processing. Explicit cancellation removes the incomplete item. Deletion is valid from every visible state. Retrieval accepts only indexed items.

### Citation availability

`available → source deleted`

Deleting a knowledge item does not mutate retained answer text or erase the provenance record; it removes preview resolution and changes the citation's displayed availability.

## Prompt composition

General turns receive instructions, the context summary when present, recent turns, and the current user message.

Knowledge Base turns receive grounded-answer instructions, the context summary when present, recent user/assistant turns for conversational interpretation, fresh evidence passages, and the current user message. Prompt composition must clearly separate conversation text from evidence and must never present assistant text as source material.

The token counter admits whole prompt sections within the measured budget. Evidence passages are never truncated in a way that breaks citation meaning. When the budget is insufficient, the Conversation Engine returns a typed outcome rather than guessing.

## Test surface

The portable suite should concentrate on observable scenarios through Chat Workspace and Knowledge Base:

- General and grounded multi-turn conversations.
- No fallback across modes.
- Multiple-source retrieval and citation resolution.
- Source changes between turns and provenance stability.
- Regeneration after source changes or deletion.
- Long-chat summary creation without transcript loss.
- Retention preview and reaping.
- Interrupted generation and global exclusivity.
- Resumable indexing with no partial retrieval.
- Duplicate detection and cascade deletion.
- Deleted-source citation behavior.
- Model-unavailable degradation.

Native tests remain focused on the thin Apple adapters and app protection. UI tests assert behavior through the same module interfaces rather than mocking internal orchestration.

## Deliberate non-designs

- No cloud provider interface beyond the already justified native/fake capability seams.
- No generic repository layer over SQLite.
- No event bus for local state propagation.
- No background-processing promise iOS cannot guarantee.
- No abstraction for future platforms that are not in scope.
- No model-generated claim-to-citation mapping unless it becomes independently verifiable.
