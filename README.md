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

The app imports pasted text into a persistent, app-private SQLite library. Import visibly advances through extraction, chunking, embedding, and indexing. A document must be selected explicitly before asking a question.

Retrieval combines SQLite FTS5/BM25 and quantized dense vectors with reciprocal-rank fusion. Only whole chunks that fit the context budget are sent to the on-device answer seam, and grounded answers display an application-owned source citation. Unsupported questions return the fixed insufficient-evidence response.

Production capability adapters are still pending. Windows development uses deterministic fake embedding, token-counting, and language-model implementations; no fake or production native capability may perform network I/O. The SwiftUI guardrail harness under `spikes/` remains disposable and independent of the Flutter application.

Library data is stored in the platform application-support directory as `sekret-midget.sqlite3`. Delete removes the selected document together with its chunks, search index entries, and vectors.
