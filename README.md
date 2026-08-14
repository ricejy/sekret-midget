# Sekret Midget

Private, on-device document questions and grounded answers. The production app is iPhone-first; portable Dart logic and fake-backed UI are developed and tested on Windows.

## Toolchain

- Flutter `3.44.9` (stable)
- Dart `3.12.2`
- Windows desktop and iOS project targets

The Flutter version is pinned in `.flutter-version` and `pubspec.yaml`. Install that exact stable SDK release before running project commands. Application dependency resolution is pinned by `pubspec.lock`.

## Windows development

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Ticket #2 is a deliberately small production tracer bullet. It uses a built-in fictional employment agreement and fake native capabilities. The SwiftUI guardrail harness under `spikes/` remains disposable and independent of the Flutter application.

No fake or production native capability may perform network I/O.
