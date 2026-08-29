import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/library/document_library.dart';
import '../core/platform/apple_foundation_models.dart';
import '../core/platform/llm_backend.dart';
import '../core/question/document_question_service.dart';

const _evaluationTitle = 'Fictional Foundation Models Evaluation';
const _evaluationText = '''
NOTICE PERIOD

Either fictional party may end employment by providing forty-five calendar days of written notice.

COMPENSATION DATE

The fictional monthly salary is paid on the tenth business day of each month.
''';

final class FoundationModelsEvaluationException implements Exception {
  const FoundationModelsEvaluationException(this.message);

  final String message;
}

final class FoundationModelsEvaluationReport {
  const FoundationModelsEvaluationReport({
    required this.contextSize,
    required this.instructionTokens,
    required this.promptTokens,
    required this.importStages,
    required this.supportedSnapshots,
    required this.supportedAnswerGrounded,
    required this.citationResolvedByApp,
    required this.unsupportedSnapshots,
    required this.exactAbstention,
    required this.elapsedMilliseconds,
  });

  final int contextSize;
  final int instructionTokens;
  final int promptTokens;
  final List<String> importStages;
  final int supportedSnapshots;
  final bool supportedAnswerGrounded;
  final bool citationResolvedByApp;
  final int unsupportedSnapshots;
  final bool exactAbstention;
  final int elapsedMilliseconds;

  bool get passed =>
      contextSize > 0 &&
      instructionTokens > 0 &&
      promptTokens > 0 &&
      importStages.contains(ImportStage.complete.name) &&
      supportedSnapshots > 0 &&
      supportedAnswerGrounded &&
      citationResolvedByApp &&
      exactAbstention;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'passed': passed,
    'contextSize': contextSize,
    'instructionTokens': instructionTokens,
    'promptTokens': promptTokens,
    'importStages': importStages,
    'supportedSnapshots': supportedSnapshots,
    'supportedAnswerGrounded': supportedAnswerGrounded,
    'citationResolvedByApp': citationResolvedByApp,
    'unsupportedSnapshots': unsupportedSnapshots,
    'exactAbstention': exactAbstention,
    'elapsedMilliseconds': elapsedMilliseconds,
  };
}

Future<FoundationModelsEvaluationReport> evaluateFoundationModels({
  required DocumentLibrary library,
  required AppleFoundationModels foundationModels,
}) async {
  if (await foundationModels.availability() is! Available) {
    throw const FoundationModelsEvaluationException(
      'The on-device model is not available.',
    );
  }

  final stopwatch = Stopwatch()..start();
  final contextSize = await foundationModels.contextWindowSize();
  final instructionTokens = await foundationModels.countInstructionTokens(
    guardrailV1Instructions,
  );
  final promptTokens = await foundationModels.countPromptTokens(
    buildGuardrailV1Prompt(
      question: 'How much advance warning is needed to end the job?',
      evidence: const [_evaluationText],
    ),
  );

  for (final document in await library.listDocuments()) {
    if (document.title == _evaluationTitle) {
      await library.deleteDocument(document.id);
    }
  }

  final importStages = <String>[];
  LibraryDocument? document;
  await for (final progress in library.importPastedText(
    title: _evaluationTitle,
    text: _evaluationText,
  )) {
    importStages.add(progress.stage.name);
    if (progress.stage == ImportStage.failed) {
      throw const FoundationModelsEvaluationException(
        'The fictional document import failed.',
      );
    }
    document = progress.document ?? document;
  }
  if (document == null) {
    throw const FoundationModelsEvaluationException(
      'The fictional document was not persisted.',
    );
  }

  var supportedSnapshots = 0;
  DocumentQuestionOutcome? supportedOutcome;
  await for (final update in library.askStream(
    documentId: document.id,
    question: 'How much advance warning is needed to end the job?',
  )) {
    switch (update) {
      case AnswerTextUpdate():
        supportedSnapshots += 1;
      case AnswerCompleted(outcome: final outcome):
        supportedOutcome = outcome;
    }
  }
  final grounded = supportedOutcome is GroundedAnswer ? supportedOutcome : null;
  final normalizedAnswer = grounded?.text.toLowerCase() ?? '';
  final supportedAnswerGrounded =
      normalizedAnswer.contains('forty-five') ||
      normalizedAnswer.contains('45');
  final citationResolvedByApp =
      grounded?.citation.heading == 'NOTICE PERIOD' &&
      grounded!.citation.passage.contains('forty-five calendar days');

  var unsupportedSnapshots = 0;
  DocumentQuestionOutcome? unsupportedOutcome;
  await for (final update in library.askStream(
    documentId: document.id,
    question: 'What color is the manager’s car under the notice period?',
  )) {
    switch (update) {
      case AnswerTextUpdate():
        unsupportedSnapshots += 1;
      case AnswerCompleted(outcome: final outcome):
        unsupportedOutcome = outcome;
    }
  }
  final exactAbstention = unsupportedOutcome is InsufficientEvidence;
  stopwatch.stop();

  await library.deleteDocument(document.id);
  return FoundationModelsEvaluationReport(
    contextSize: contextSize,
    instructionTokens: instructionTokens,
    promptTokens: promptTokens,
    importStages: List.unmodifiable(importStages),
    supportedSnapshots: supportedSnapshots,
    supportedAnswerGrounded: supportedAnswerGrounded,
    citationResolvedByApp: citationResolvedByApp,
    unsupportedSnapshots: unsupportedSnapshots,
    exactAbstention: exactAbstention,
    elapsedMilliseconds: stopwatch.elapsedMilliseconds,
  );
}

final class FoundationModelsEvaluationApp extends StatelessWidget {
  const FoundationModelsEvaluationApp({super.key, required this.reportFuture});

  final Future<FoundationModelsEvaluationReport> reportFuture;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Foundation Models evaluation')),
        body: FutureBuilder<FoundationModelsEvaluationReport>(
          future: reportFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              debugPrint(
                'FOUNDATION_MODELS_EVALUATION_ERROR='
                '${snapshot.error.runtimeType}',
              );
              return const _EvaluationFailure();
            }
            if (snapshot.data case final report?) {
              debugPrint(
                'FOUNDATION_MODELS_EVALUATION_JSON=${jsonEncode(report.toJson())}',
                wrapWidth: 1000000,
              );
              return _EvaluationResult(report: report);
            }
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Testing the on-device model with fictional text…'),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _EvaluationResult extends StatelessWidget {
  const _EvaluationResult({required this.report});

  final FoundationModelsEvaluationReport report;

  @override
  Widget build(BuildContext context) {
    final checks = <String, bool>{
      'Persistent pasted-text import': report.importStages.contains(
        ImportStage.complete.name,
      ),
      'Exact model context and token APIs':
          report.contextSize > 0 &&
          report.instructionTokens > 0 &&
          report.promptTokens > 0,
      'Streaming grounded answer':
          report.supportedSnapshots > 0 && report.supportedAnswerGrounded,
      'App-owned citation': report.citationResolvedByApp,
      'Exact unsupported-evidence abstention': report.exactAbstention,
    };
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          report.passed ? 'All checks passed' : 'A check failed',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Completed on-device in ${report.elapsedMilliseconds} ms. '
          'Context: ${report.contextSize} tokens.',
        ),
        const SizedBox(height: 20),
        for (final check in checks.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              check.value ? Icons.check_circle : Icons.error,
              color: check.value ? Colors.green : Colors.red,
            ),
            title: Text(check.key),
          ),
        const SizedBox(height: 16),
        const Text(
          'For the offline acceptance check, enable airplane mode, relaunch '
          'this build, and confirm that all checks pass again.',
        ),
      ],
    );
  }
}

final class _EvaluationFailure extends StatelessWidget {
  const _EvaluationFailure();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'The on-device evaluation could not complete. Check model '
          'availability and the sanitized Flutter console marker.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
