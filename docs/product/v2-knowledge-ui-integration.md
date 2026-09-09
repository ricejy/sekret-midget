# Knowledge Base catalogue and preview

Issue #26 replaces the opt-in v2 Knowledge Base landing screen with the
Variant A native catalogue. The v1 default launch and production database are
unchanged. Enable `SEKRET_V2` only against an existing v2 vault; an unrecognized
v1 schema is still refused without a reset.

## Interface

- Lazy date-grouped rows show title, source type, original byte size, known page
  count, processing state and checkpoint progress. The count reflects the current
  local query and filters. Search covers titles, source names and extracted text,
  never chats, and opens the matching page/passage.
- Add offers pasted text, PDF and photograph. Binary sources use the existing
  native Files pickers; cancelling a picker adds nothing. Text admission requires
  a non-empty title and body. The shared KnowledgeBase module retains originals,
  detects duplicates, and owns all indexing/recovery work.
- Duplicates offer Keep existing or Open existing. A newly admitted source clears
  filters so it is not invisibly added to a filtered-out catalogue.
- Swipe right to Rename; swipe left to confirm Delete. The row's labelled actions
  button exposes those same operations without a gesture, plus Retry, Re-index,
  and Cancel import where applicable. Re-indexing explains the temporary loss of
  evidence readiness. Cancellation discards an incomplete original; an item that
  finishes indexing before cancellation requires the separate Delete action.
- Deletion explicitly warns that source/index data is removed but related chat
  text may retain sensitive derived information. There is no source-delete Undo.

## Shared read-only preview

`SourcePreview` receives the KnowledgeBase and a location, not an immutable copy
of original bytes. Catalogue rows and Chat citations use the same destination.
It subscribes to changes and invalidates the visible original after deletion in
another tab. Processing updates expose newly available extracted pages.

Pasted text is selectable, with native long-press Copy. PDF originals use pdfrx
with page controls, native text selection and pinch zoom. Photographs use an
interactive original image. PDF/photo previews have an Extracted text switch;
recognized text remains independently selectable and searchable. Source
information contains metadata, processing diagnostics and low-confidence OCR
warnings. Missing native PDF rendering or malformed images produce a readable
fallback; available extracted text remains usable.

Local literal search navigates occurrences across available extracted pages and
selects/scrolls the matching clean text. Native PDF text matches are highlighted
only when pdfrx supplies real text geometry. OCR results navigate the original
page, not invented coordinates on a scan or photo. Citation locations preserve
the requested page and show the captured passage. External PDF links have no
handler and do not trigger network or browser navigation.

## Verification

`test/knowledge_screen_test.dart` exercises the public UI with a real in-memory
vault/KnowledgeBase and deterministic platform adapters. Coverage includes
catalogue search and filters, 500 items at large text size, import/duplicates,
rename, retained-chat deletion confirmation, preview invalidation, long-press
Copy, match navigation, failed retry/cancellation, re-index/pause/recovery, PDF,
scanned PDF and photo originals/extracted text, and original page/zoom controls.
Dark mode, large text, a source disappearing during an action, and deletion of
every original type are covered as well. Action errors remain visible across
catalogue refreshes. Closing/deleting a photo preview evicts its decoded image;
processing notifications preserve immutable original-byte identity to avoid
unnecessary PDF/image reloads.

`integration_test/knowledge_ui_test.dart` reuses the scenarios on iPhone with real
pdfrx loading, rendering and scan rasterization. File selection, embeddings and
OCR remain deterministic test adapters; system picker interaction and OCR quality
are not inferred from those tests. Native OCR and privacy acceptance remain part
of the established native tests and final #29 release gate.

Small fictional PDF, scan and photo originals are generated in memory by test
code, not bundled as production assets. Portable PDF tests cover the unavailable
native-renderer fallback and extracted text; physical tests additionally require
the PDF renderer to become ready, report the correct page count, and zoom.

Optional Mac visual snapshots use system fonts without bundling them:

```sh
flutter test test/knowledge_screen_test.dart --plain-name 'dark mode' \
  --dart-define=WRITE_KNOWLEDGE_SCREENSHOTS=true
```

The generated catalogue, dark catalogue and large-text preview PNGs go to
`/private/tmp/sekret-knowledge-*.png`, not source control.

Device command (USB, unlocked; preserve existing app data):

```sh
flutter test integration_test/knowledge_ui_test.dart \
  -d 00008130-001E182A2190001C --no-uninstall
```

After device tests, restore the normal release app with `flutter run --release
--no-resident -d 00008130-001E182A2190001C -t lib/main.dart`. No test opens or resets
the production vault. Settings/app protection remain #27; final accessibility,
airplane-mode and app-targeted network verification remain #28/#29.

## Recorded checks — 2026-09-09

- Static analysis: clean.
- Complete portable suite: 171 passed.
- Physical iPhone 15 Pro Max, iOS 26.6.1, USB: all 12 Knowledge Base UI
  scenarios passed in 3 minutes 29 seconds, using `--no-uninstall`.
- Real-font light/dark catalogue and large-text preview snapshots inspected.
