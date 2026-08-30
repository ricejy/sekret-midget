# Sekret Midget

Private, on-device document questions and grounded answers. The production app is iPhone-first; portable Dart logic and fake-backed UI are developed and tested on Windows.

## Toolchain

- Flutter `3.44.9` (stable)
- Dart `3.12.2`
- Windows desktop and iOS project targets

The Flutter version is pinned in `.flutter-version` and `pubspec.yaml`. Install that exact stable SDK release before running project commands. Application dependency resolution is pinned by `pubspec.lock`.

## Windows development

Enable **Developer Mode** under **Settings → System → Advanced → For developers** before resolving dependencies. Flutter desktop plugins use symbolic links on Windows.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

## Current application slice

The app imports pasted text, PDFs, and document photos into a persistent, app-private SQLite library. File selection uses the operating system picker. `pdfrx` extracts PDF text locally page by page; pages without a text layer are rasterized locally and routed through Apple Vision OCR, as are selected photos. Import visibly advances through extraction, OCR when needed, chunking, embedding, and indexing. A document must be selected explicitly before asking a question.

Retrieval combines SQLite FTS5/BM25 and quantized dense vectors with reciprocal-rank fusion. Only whole chunks that fit the context budget are sent to the on-device answer seam, and grounded answers display an application-owned source citation. Extracted and OCR-recognized PDF pages retain their page and section association; photos cite page one. OCR failures, low-confidence recognition, and insufficient recognized text are reported explicitly. Malformed, unsupported, failed, and cancelled imports leave no queryable partial document. Unsupported questions return the fixed insufficient-evidence response.

On iOS, sentence embeddings come from Apple's Natural Language framework and OCR comes from Apple Vision through narrow method-channel adapters. The OCR bridge accepts only supplied encoded images or rendered page pixels, returns recognized text and confidence, and has no network path. The app reports the available English embedding model's runtime dimension and revision, validates native results, and keeps Apple framework types out of Dart. Imports and questions map native failures to explicit, recoverable application outcomes without exposing document text. These paths continue to work in airplane mode once the operating system provides the required models.

Windows development uses a deterministic fake embedding implementation so quantization, persistence, dense retrieval, and reciprocal-rank fusion remain portable and testable. Production token-counting and language-model adapters are still pending. The SwiftUI guardrail harness under `spikes/` remains disposable and independent of the Flutter application.

Library data is stored in the platform application-support directory as `sekret-midget.sqlite3`. Imported PDF and photo bytes are held in the same protected local database as their page-aware chunks. Delete removes the selected document together with its source bytes, chunks, search index entries, and vectors. The production pickers, PDF processing, and OCR adapters operate only on local bytes and contain no application network calls.

## Retrieval quality benchmark

The repository includes a labeled, entirely fictional contract-and-policy corpus for measuring recall@4 through the production chunking and retrieval path. It compares hybrid retrieval with dense-only retrieval using the same fixtures and query strings. See [the retrieval evaluation runbook](docs/evaluation/retrieval-quality.md) for portable and physical-iPhone commands, configuration details, and the recorded baseline.
