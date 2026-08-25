import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/library/document_library.dart';
import 'core/platform/apple_embedder.dart';
import 'core/platform/embedder.dart';
import 'demo/fake_native_capabilities.dart';
import 'evaluation/retrieval_quality_app.dart';

const _runRetrievalQualityEvaluation = bool.fromEnvironment(
  'RETRIEVAL_QUALITY_EVALUATION',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_runRetrievalQualityEvaluation) {
    runApp(
      RetrievalQualityEvaluationApp(
        documentLibraryFuture: _openEvaluationLibrary(),
        tokenCounterImplementation: 'Deterministic whitespace counter',
      ),
    );
    return;
  }
  runApp(SekretMidgetApp(documentLibraryFuture: _openPersistentLibrary()));
}

Future<DocumentLibrary> _openPersistentLibrary() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final databasePath =
      '${supportDirectory.path}${Platform.pathSeparator}sekret-midget.sqlite3';
  return openDocumentLibrary(
    databasePath: databasePath,
    embedder: _platformEmbedder(),
    llmBackend: const FakeLlmBackend(),
    tokenCounter: const FakeTokenCounter(),
  );
}

Future<DocumentLibrary> _openEvaluationLibrary() {
  return openDocumentLibrary(
    databasePath: ':memory:',
    embedder: _platformEmbedder(),
    llmBackend: const FakeLlmBackend(),
    tokenCounter: const FakeTokenCounter(),
  );
}

Embedder _platformEmbedder() =>
    Platform.isIOS ? AppleEmbedder() : const FakeEmbedder();
