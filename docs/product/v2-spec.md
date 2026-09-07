# Sekret v2 product specification

- **Status:** Confirmed product scope
- **Confirmed:** 2026-09-07
- **Production implementation:** Not started

## Objective

Refine the proven private-document v1 into **Sekret**, a calm, iPhone-first general chat application with an explicitly controlled personal Knowledge Base. General chat and document-grounded chat coexist without blurring their provenance, while generation, retrieval, storage, search, and conversation memory remain entirely local.

The refinement must preserve the v1 guarantees already demonstrated on the target iPhone: offline operation, no application network traffic, grounded citations, exact insufficient-evidence behavior, local OCR and embeddings, reliable deletion of source indexes, and portable fake-backed tests on Windows.

## Product promise

- Chat, knowledge processing, history, summaries, and search stay on the device.
- No account is required.
- A general answer is visibly different from a grounded answer.
- The app never silently supplements missing document evidence with general model knowledge.
- A chat knows only its own history; there is no cross-chat memory.
- Users explicitly control which knowledge items are eligible for future grounded turns.
- Privacy-sensitive deletion consequences are stated before the user acts.

## Product identity

- User-facing name: **Sekret**.
- Repository name, Dart package name, iOS bundle identifier, and database filename remain unchanged.
- Tone: clear, calm, concise by default, and more detailed only when requested.
- There is no named assistant persona.
- Visual character: quiet, premium, and native to iPhone rather than decorative or stereotypically “AI.”

## Information architecture

Sekret has three bottom tabs.

### Chat

The primary surface. It opens the current chat and provides access to searchable chat history and New Chat.

### Knowledge Base

The catalogue for importing, processing, searching, previewing, renaming, retrying, re-indexing, and deleting local knowledge items.

### Settings

The home for model availability, privacy and retention controls, storage management, app lock, destructive data actions, and version-safe diagnostics.

## Chat experience

### Chat lifecycle

- Starting a new chat preserves the previous chat in local history.
- New chats begin in General mode with no selected sources.
- The top-left navigation action opens searchable history.
- The top-right navigation action starts a new chat.
- History provides deterministic automatic titles derived from the first user message, rename, local full-text search, and swipe-to-delete with a brief Undo action.
- There is no cross-chat memory, preference carry-over, or implicit reuse of sources.
- One assistant generation may run globally at a time. Prompts are not queued.
- The send action becomes Stop while generation is active.
- Generation may continue while moving between tabs as long as the app remains active.
- A response interrupted by stopping or suspension remains visibly incomplete and may be regenerated.

### Modes and sources

- The composer exposes a persistent, visible General / Knowledge Base mode control.
- In Knowledge Base mode, selected-source chips appear above the composer.
- The source control opens a searchable multi-select sheet.
- Multiple explicitly selected knowledge items may be used by one chat.
- Processing items may be selected in anticipation, but asking remains disabled until every required source is indexed.
- The chat remembers its current selected sources.
- Changing selected sources affects future turns only.
- Each turn records its original mode and source scope.
- Regenerate uses the original mode and source scope unless the user submits a new turn.

### General mode

- The assistant answers from the on-device model without consulting the Knowledge Base.
- Responses are visibly labelled `General answer`.
- Legal, medical, and financial questions receive concise contextual caution rather than blanket refusal or false certainty.
- General answers do not display knowledge-base citations.

### Knowledge Base mode

- Each turn uses recent chat context and the context summary to interpret follow-up language.
- Every turn performs fresh retrieval across the source scope captured for that turn.
- Only currently retrieved evidence passages may support the new answer.
- Earlier assistant statements are never treated as evidence.
- When evidence is insufficient, the result remains exactly: `I couldn’t find enough evidence in this document.`
- Insufficient evidence never falls back automatically to General mode.
- The UI may offer a separate `Ask as general question` action that creates a deliberate General-mode turn.
- Grounded answers are labelled `Based on selected sources` or `Based on N sources`.

### Responses and citations

- Streaming text renders in place.
- Responses support headings, lists, emphasis, responsive tables, and code blocks with Copy.
- Links are not opened without an explicit user action.
- Grounded answers show an expandable Sources section containing application-owned source cards.
- Inline citation markers appear only where the application can establish exact attribution; approximate claim-level citations are prohibited.
- A source card identifies its knowledge item, page and section when present, and supporting evidence passage.
- Tapping an available citation opens the source preview at the relevant location.
- A citation whose knowledge item was deleted is marked `Source deleted` and cannot open a preview.

### Message actions

- Copy and select text.
- Regenerate with the turn's original provenance.
- Delete the selected message and every later turn in that chat.
- Editing with branches, sharing, reporting, and export are excluded.

## Conversation memory and retention

- Complete transcripts are persisted locally.
- Context fitting and storage retention are separate concerns.
- A local context summary distills older turns for the model while the full visible transcript remains unchanged.
- The prompt uses the context summary, recent turns, newly retrieved evidence where applicable, and the current user message.
- The UI shows a subtle `Earlier conversation summarized` indication when a summary contributes to the prompt.
- Default retention is until manual deletion.
- Optional retention periods are 30 or 90 days after the chat's latest activity.
- Reaping permanently deletes complete chats, not individual old turns.
- Reaping runs locally when the app launches or resumes.
- Changing to a shorter retention period previews how many chats are affected and requires confirmation.
- There is no hidden storage quota that removes chats unexpectedly.

## Knowledge Base

### Catalogue

- Compact native list, not a card grid.
- Search field at the top.
- Filters for source type and processing state.
- Rows grouped by import date.
- Each row shows title, source type, page count where applicable, source size, and processing state.
- Active processing progress appears in the row.
- Swipe actions provide Rename and Delete.
- Tapping a row opens its preview.
- The primary Add action offers pasted text, PDF, and photograph inputs.
- Chat contains an `Add to Knowledge Base` shortcut that navigates here; it does not bypass this ingestion flow.

### Search

- Search is entirely local.
- It covers titles, metadata needed for filtering, and extracted document text.
- Content matches reveal a minimal passage and open the matching location in Preview.
- Knowledge Base search does not search chat messages; Chat history owns that behavior.

### Processing lifecycle

- Processing states are processing, paused, indexed, failed, and needs re-indexing.
- Only indexed knowledge items contribute evidence.
- iOS background execution is not assumed.
- Safe page-level intermediate work may be retained when processing is interrupted.
- Interrupted work resumes when the app returns to the foreground.
- Failed and paused items remain visible with Retry and Delete.
- Explicit cancellation discards the incomplete import.
- Partial indexes are never queryable.

### Duplicate handling

- Byte-identical PDF and photograph imports are detected before repeated indexing.
- Normalized pasted-text content is eligible for the same duplicate check.
- A duplicate offers to open the existing knowledge item.
- Identical titles are allowed when content differs.
- Replacement and document versioning are excluded.

## Document preview

- Pasted text uses a selectable clean-text view.
- PDFs render their original pages.
- Photographs render their original image.
- PDF and image views support pinch-to-zoom.
- Preview provides page navigation and local search.
- An optional extracted-text/OCR view exposes what retrieval can search.
- Citation navigation opens the correct page and highlights or scrolls to the supporting passage where technically reliable.
- Metadata and OCR/indexing warnings are accessible from an information action.
- Editing and annotation are excluded.

## Deletion semantics

### Delete chat

- Swipe deletion offers a brief Undo action, after which the chat is permanently removed.

### Delete knowledge item

- The app identifies that related chats may retain derived sensitive information.
- Confirmation explicitly states that the source and index will be deleted while chat text remains.
- Confirmation permanently removes source bytes, extracted text, chunks, full-text entries, vectors, and processing artifacts.
- Related messages remain unchanged.
- Their citations become `Source deleted`.

### Erase all local data

- Removes every chat, summary, source selection, knowledge item, processing artifact, and local preference that contains or describes user content.
- Requires biometric or normal device authentication and an explicit irreversible confirmation.

### Transition from v1

Existing v1 local documents do not require migration. The owner's development device may receive a one-time destructive reset during the transition, confirmed immediately before execution. The v2 schema should establish an explicit migration policy for later revisions rather than normalizing destructive upgrades.

## Settings

- Apple Intelligence and on-device model availability.
- Local-only privacy status and explanation.
- Chat retention: manual, 30 days, or 90 days.
- Local storage usage by chats, knowledge sources, and indexes.
- Delete all chats.
- Delete the entire Knowledge Base with linked-chat warning.
- Erase all local data.
- Optional Face ID or Touch ID app lock.
- Lock delay: immediately, one minute, or fifteen minutes.
- Normal iOS device-passcode fallback.
- App version, OS/model-runtime information, and content-free diagnostics.
- System appearance only; no custom theme selector.

## Security and privacy behavior

- The iOS application sandbox and explicit file protection remain the storage-security model.
- Custom database encryption and application-managed keys are excluded.
- Sensitive content is always obscured in the iOS app-switcher snapshot.
- Notifications never contain document or chat content.
- Permissions are requested only when the user initiates an operation requiring them.
- Face ID protects entry to the interface but is not represented as database encryption.
- No application feature requires network access.

## Model-unavailable behavior

When generation is unavailable, users may still browse history, search and preview knowledge, import or index where the remaining native capabilities permit it, change settings, and delete data. The composer is disabled with a specific explanation and appropriate recovery action for unsupported device, disabled Apple Intelligence, or model assets not ready.

## Visual language

- Cupertino-first tab shell, navigation bars, sheets, menus, and interaction conventions.
- Deep navy text, soft off-white surfaces, restrained blue actions, amber warnings, and sparing green success states.
- System typography, generous spacing, high contrast, and full light/dark support.
- User turns use compact right-aligned bubbles.
- Assistant responses use a clean full-width layout.
- The header carries a subtle `On device` status rather than repeating it on every response.
- The empty Chat surface provides a quiet introduction, Knowledge Base action, and two or three understated example prompts.
- Motion is subtle and respects Reduce Motion.
- Gradients, glass effects, neon AI styling, mascots, decorative typing animations, and marketing carousels are excluded.

## Accessibility

- Dynamic Type, including large accessibility sizes.
- VoiceOver labels and logical traversal.
- Sufficient color contrast without relying on color alone.
- Keyboard-safe composer and preview layouts.
- Reduce Motion support.
- Minimum native touch-target sizing.
- Status, mode, source selection, generation progress, and citation availability are semantically exposed.

## Explicit exclusions

- Cloud models, user-supplied provider keys, accounts, subscriptions, and billing.
- Synchronization, backup, sharing, and export.
- Web browsing and live search.
- Voice input or voice conversation.
- Camera or image understanding directly in Chat.
- File attachments that bypass the Knowledge Base.
- Agentic tools or external actions.
- Cross-chat memory.
- Concurrent generations and prompt queues.
- Document editing, annotation, replacement, and versioning.
- Android, desktop, and iPad-specific production interfaces.

## Acceptance gate

The refinement is complete only when:

- Chat, Knowledge Base, and Settings are complete and visually coherent.
- General and Knowledge Base modes remain visibly and behaviorally distinct.
- Persistent history, local search, rename, deletion, retention, reaping, and context summaries work as specified.
- Multi-source retrieval preserves immutable per-turn provenance and reliable citation navigation.
- Catalogue processing states, resume behavior, duplicate detection, search, and document preview work across all supported inputs.
- Onboarding, model-unavailable states, biometric lock, app-switcher protection, and destructive data actions work on the target device.
- Accessibility checks cover Dynamic Type, VoiceOver, contrast, keyboard behavior, and Reduce Motion.
- Static analysis and the complete portable suite pass on Windows.
- Native bridge and platform integration tests pass on the Mac.
- A signed Release build passes on the iPhone 15 Pro Max.
- Airplane Mode and app-targeted network verification are repeated.
- Retrieval recall, guardrail acceptance, citations, insufficient-evidence wording, indexing integrity, and deletion integrity do not regress.

## Delivery order

1. Confirm this product specification and domain language.
2. Compare interactive UI shell variants and select a direction.
3. Publish a sequenced GitHub roadmap of independently testable tickets.
4. Implement only after the prototype direction and ticket sequence are approved.
5. Repeat the complete release gate before declaring the refinement complete.
