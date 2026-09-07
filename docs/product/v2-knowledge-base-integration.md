# Knowledge Base integration

Issue #23 introduces the v2 `KnowledgeBase` module. Processing, recovery,
catalogue search, preview descriptors and evidence readiness live here, rather
than in the future tab widgets. It uses the shared local vault, not a second
database or a wrapper around the v1 `DocumentLibrary`.

The v1 visible application is unchanged. #26 supplies the native-style catalogue
and PDF/image/text preview widgets; this ticket supplies their data and location
descriptors. No v1 documents are reset. Keep the existing v1 tests until its UI
is retired: they still exercise a shipped caller, not redundant wrappers.

## Composition

Open one `KnowledgeBase` for the vault lifetime, supplying the existing
`AppleEmbedder`, token counter, `PdfrxDocumentLoader`, PDF rasterizer and OCR
adapter. The portable tests supply deterministic adapters at these same seams.
No model generation, network access or chat-history access is needed.

Subscribe to `changes`, then refresh `catalogue()`. It returns import-date-ordered
items, including processing state, original byte size, source type, page count,
safe processing messages and checkpoint progress. Literal local queries cover
titles, source names and extracted page text, with optional type/state filters.
Search does not load PDF/image bytes or search chat messages. A content match
returns a short excerpt and a page/query location for preview.

## Import and lifecycle

- `importText` or `importSource` retains a defensive copy of the original and
  returns its identity immediately while processing continues. Re-render from
  `changes`; `process(id)` can also be awaited for a terminal record.
- SHA-256 fingerprints detect byte-identical PDF/photo imports. Pasted-text
  fingerprints trim and collapse whitespace but preserve case. The original
  text stays unchanged for preview. Duplicate admission is serialized, returns
  the existing item, and never starts a second indexing job. The caller offers
  to open that item. Same-title/different-content sources remain separate.
- Safe extraction is committed page by page. Missing PDF text layers are
  rasterized/OCR'd one page at a time. OCR confidence is retained per page;
  preview exposes a warning below the existing 0.55 threshold. The existing
  minimum-readable-OCR rule is unchanged.
- `suspend()` stops admission and requests existing jobs to pause at safe points.
  It waits for in-flight native operations to return; it does not assume iOS
  background execution or pretend to abort a native call that lacks that
  capability. Results arriving after pause are discarded before the next write.
- Opening the module turns abandoned `processing` items into `paused`.
  `resume()` retries paused work sequentially in the foreground. Completed pages
  are reused; an interrupted page is redone. Embeddings are regenerated from
  retained pages, rather than persisting a partially searchable index.
- Failed items retain originals and safe diagnostics. `process(id)` retries;
  `invalidateIndex(id)` marks an existing index `needsReindexing`, immediately
  excluding it from evidence. A subsequent `process` explicitly rebuilds it.
- `cancelImport(id)` pauses and discards incomplete work. It rejects indexed
  items so a late cancellation cannot bypass the confirmed-deletion interaction.
- Dispose this module before closing the vault. Native operations must settle
  before disposal completes; do not close the database while a job is active.

## Evidence, preview and deletion

Only `indexed` items return evidence. Chunking, vector quantization, lexical query
composition, cosine ranking, reciprocal-rank fusion and production configuration
are shared with v1 in `knowledge_algorithms.dart`. The v2 retrieval interface
returns the top four single-source candidates. #24 owns multi-source combination
and exact grounded-prompt admission. Retrieval rechecks state after native query
embedding, so deleted or invalidated sources cannot leak stale candidates.

`preview(location)` returns original source bytes, source metadata, extracted
pages, OCR confidence and the requested page/text location, or null if deleted.
For text sources, decode the original UTF-8 bytes into a selectable view. For
PDF/photo sources, render the original bytes. Extracted pages are a separate
optional view and may be incomplete while processing. The text in a location
is a literal search/scroll target, not a claim of exact PDF-image coordinates.
`resolveCitation` rechecks current source availability even for an older citation
snapshot. Re-indexing preserves the known original page count so existing
citations can still open the original while derivatives are rebuilt.

`delete(id)` owns job coordination and complete source cleanup. Call it only
after the UI confirms that source/index data will be removed while existing
chats may retain derived text. Original bytes, page text, chunks, FTS entries,
vectors and checkpoints are deleted together. Retained turn provenance remains
readable and resolves as `Source deleted`; no stale callback recreates the source.

## Storage and verification

Schema 4 adds extracted pages and a safe processing-message column through
transactional migrations. Source page text participates in logical storage
accounting and cascade deletion. Original byte size is measured by SQLite.
Older vaults preserve source content; no destructive upgrade is performed.

Tests exercise the public Knowledge Base interface with SQLite and fake native
adapters: original previews, search locations, text/binary duplicates, concurrent
duplicate admission, mixed PDF OCR, warnings, failures/retry, interruption/reopen,
partial-index isolation, cancellation, re-indexing, deletion and citation retention.
The same fictional 30-question corpus passes in both v1 and v2, in hybrid and
dense-only modes. Actual preview rendering/zoom and lifecycle wiring are verified
when #26 integrates the UI; this ticket does not claim those widgets are built.
