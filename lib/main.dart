import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/library/document_library.dart';
import 'demo/fake_native_capabilities.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDirectory = await getApplicationSupportDirectory();
  final databasePath =
      '${supportDirectory.path}${Platform.pathSeparator}sekret-midget.sqlite3';
  final documentLibrary = await openDocumentLibrary(
    databasePath: databasePath,
    embedder: const FakeEmbedder(),
    llmBackend: const FakeLlmBackend(),
    tokenCounter: const FakeTokenCounter(),
  );
  runApp(SekretMidgetApp(documentLibrary: documentLibrary));
}
