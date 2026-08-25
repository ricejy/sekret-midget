import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/library/document_library.dart';
import 'core/platform/apple_embedder.dart';
import 'core/platform/embedder.dart';
import 'demo/fake_native_capabilities.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SekretMidgetApp(documentLibraryFuture: _openPersistentLibrary()));
}

Future<DocumentLibrary> _openPersistentLibrary() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final databasePath =
      '${supportDirectory.path}${Platform.pathSeparator}sekret-midget.sqlite3';
  final Embedder embedder = Platform.isIOS
      ? AppleEmbedder()
      : const FakeEmbedder();
  return openDocumentLibrary(
    databasePath: databasePath,
    embedder: embedder,
    llmBackend: const FakeLlmBackend(),
    tokenCounter: const FakeTokenCounter(),
  );
}
