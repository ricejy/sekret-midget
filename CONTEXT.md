# Sekret

Sekret is a private, local assistant that can chat generally or answer from an explicitly chosen personal knowledge base. This glossary names the concepts that must remain consistent across product design, implementation, and tests.

## Chats

**Chat**:
A locally retained sequence of turns with its own current mode and selected sources. A new chat has no knowledge of any other chat.
_Avoid_: Conversation, thread, session

**Turn**:
A user message together with the assistant response or terminal failure it caused. A turn permanently records the mode and source scope used when it began.
_Avoid_: Request, exchange

**General mode**:
A chat mode in which the assistant answers from the on-device model without consulting the knowledge base.
_Avoid_: Ungrounded mode, open mode

**Knowledge Base mode**:
A chat mode in which the assistant may answer only from evidence retrieved from the selected sources. Insufficient evidence never falls back to general knowledge.
_Avoid_: Document mode, retrieval mode

**Context summary**:
A local distillation of earlier turns used to preserve continuity within the model context limit. It does not replace or shorten the retained chat.
_Avoid_: Compressed chat, chat history

**Interrupted response**:
An assistant response that did not complete because generation was stopped or the app was suspended. It remains identifiable and may be regenerated.
_Avoid_: Failed answer

## Knowledge

**Knowledge Base**:
The local catalogue of imported knowledge items available for explicit selection in chats.
_Avoid_: Library, uploads, documents folder

**Knowledge item**:
A pasted text, PDF, scanned PDF, or photograph together with its processing state and locally derived searchable representations.
_Avoid_: File, upload, document

**Selected source**:
A knowledge item currently chosen as eligible evidence for future turns in a chat.
_Avoid_: Attachment, active document

**Turn source scope**:
The immutable set of selected sources captured when a turn begins. Later selection changes do not alter it.
_Avoid_: Current sources, active sources

**Evidence passage**:
A ranked excerpt retrieved from a source and supplied to the model for a Knowledge Base mode turn.
_Avoid_: Context, result, snippet

**Citation**:
An application-owned reference from a grounded answer to an evidence passage and its source location.
_Avoid_: Model citation, footnote

**Source deleted**:
The state of a retained citation whose knowledge item has been deleted. The chat remains readable, but the citation can no longer open its source.
_Avoid_: Broken citation, missing file

## Answers

**General answer**:
An answer produced in General mode and visibly identified as model knowledge rather than knowledge-base evidence.
_Avoid_: Normal answer, ungrounded answer

**Grounded answer**:
An answer produced in Knowledge Base mode from retrieved evidence and presented with application-owned citations.
_Avoid_: Document answer, sourced response

**Insufficient evidence**:
The Knowledge Base mode outcome used when selected sources do not adequately support an answer. Its user-facing text remains fixed and it never triggers an automatic general answer.
_Avoid_: Refusal, no answer

## Lifecycle

**Processing state**:
The current readiness of a knowledge item: processing, paused, indexed, failed, or needs re-indexing. Only indexed items may contribute evidence.
_Avoid_: Upload status, sync status

**Retention policy**:
The user-selected rule for keeping chats until manual deletion or reaping them after inactivity.
_Avoid_: Compression policy, history limit

**Reaping**:
Permanent local deletion of complete chats whose inactivity exceeds the retention policy.
_Avoid_: Summarization, archiving
