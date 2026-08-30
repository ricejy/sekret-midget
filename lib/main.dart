import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/library/document_library.dart';
import 'core/platform/apple_embedder.dart';
import 'core/platform/apple_foundation_models.dart';
import 'core/platform/embedder.dart';
import 'core/platform/pdfrx_pdf_text_extractor.dart';
import 'demo/fake_native_capabilities.dart';
import 'evaluation/foundation_models_evaluation_app.dart';
import 'evaluation/retrieval_quality_app.dart';

const _runRetrievalQualityEvaluation = bool.fromEnvironment(
  'RETRIEVAL_QUALITY_EVALUATION',
);
const _runFoundationModelsEvaluation = bool.fromEnvironment(
  'FOUNDATION_MODELS_EVALUATION',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_runFoundationModelsEvaluation) {
    runApp(
      FoundationModelsEvaluationApp(
        reportFuture: _runFoundationModelsEvaluationOnDevice(),
      ),
    );
    return;
  }
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
  return _openProtectedLibrary(databaseFilename: 'sekret-midget.sqlite3');
}

Future<DocumentLibrary> _openProtectedLibrary({
  required String databaseFilename,
}) async {
  final supportDirectory = await getApplicationSupportDirectory();
  final databasePath =
      '${supportDirectory.path}${Platform.pathSeparator}$databaseFilename';
  final foundationModels = Platform.isIOS ? AppleFoundationModels() : null;
  await foundationModels?.protectStorage(
    directoryPath: supportDirectory.path,
    databasePath: databasePath,
  );
  final library = await openDocumentLibrary(
    databasePath: databasePath,
    embedder: _platformEmbedder(),
    llmBackend: foundationModels ?? const FakeLlmBackend(),
    tokenCounter: foundationModels ?? const FakeTokenCounter(),
    pdfTextExtractor: const PdfrxPdfTextExtractor(),
  );
  try {
    await foundationModels?.protectStorage(
      directoryPath: supportDirectory.path,
      databasePath: databasePath,
    );
    return library;
  } on Object {
    await library.close();
    rethrow;
  }
}

Future<FoundationModelsEvaluationReport>
_runFoundationModelsEvaluationOnDevice() async {
  if (!Platform.isIOS) {
    throw const FoundationModelsEvaluationException(
      'This evaluation requires a physical iPhone.',
    );
  }
  final foundationModels = AppleFoundationModels();
  final library = await _openProtectedLibrary(
    databaseFilename: 'foundation-models-evaluation.sqlite3',
  );
  try {
    return await evaluateFoundationModels(
      library: library,
      foundationModels: foundationModels,
    );
  } finally {
    await library.close();
  }
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
