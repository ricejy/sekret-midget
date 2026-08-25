import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/library/document_library.dart';
import '../core/platform/embedder.dart';
import 'retrieval_quality.dart';

final class RetrievalQualityEvaluationApp extends StatefulWidget {
  const RetrievalQualityEvaluationApp({
    super.key,
    required this.documentLibraryFuture,
    required this.tokenCounterImplementation,
  });

  final Future<DocumentLibrary> documentLibraryFuture;
  final String tokenCounterImplementation;

  @override
  State<RetrievalQualityEvaluationApp> createState() =>
      _RetrievalQualityEvaluationAppState();
}

final class _RetrievalQualityEvaluationAppState
    extends State<RetrievalQualityEvaluationApp> {
  late final Future<RetrievalQualityReport> _reportFuture = _run();
  DocumentLibrary? _library;

  Future<RetrievalQualityReport> _run() async {
    final library = await widget.documentLibraryFuture;
    _library = library;
    final report = await evaluateRetrievalQuality(
      library: library,
      tokenCounterImplementation: widget.tokenCounterImplementation,
    );
    _printMachineReadableReport(report);
    return report;
  }

  void _printMachineReadableReport(RetrievalQualityReport report) {
    final reportJson = report.toJson();
    final summary = <String, Object>{
      'schemaVersion': reportJson['schemaVersion']!,
      'runAt': reportJson['runAt']!,
      'embedding': reportJson['embedding']!,
      'recallAt4Target': reportJson['recallAt4Target']!,
      'hybrid': reportJson['hybrid']!,
      'denseOnly': reportJson['denseOnly']!,
      'decision': reportJson['decision']!,
    };
    debugPrint(
      'RETRIEVAL_QUALITY_SUMMARY_JSON=${jsonEncode(summary)}',
      wrapWidth: 1000000,
    );

    final encodedReport = jsonEncode(reportJson);
    const chunkSize = 700;
    final partCount = (encodedReport.length / chunkSize).ceil();
    for (var index = 0; index < partCount; index += 1) {
      final start = index * chunkSize;
      final end = (start + chunkSize).clamp(0, encodedReport.length);
      debugPrint(
        'RETRIEVAL_QUALITY_JSON_PART=${index + 1}/$partCount:'
        '${encodedReport.substring(start, end)}',
        wrapWidth: 1000000,
      );
    }
  }

  @override
  void dispose() {
    if (_library case final library?) {
      unawaited(library.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Retrieval quality evaluation')),
        body: FutureBuilder<RetrievalQualityReport>(
          future: _reportFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _EvaluationFailure(error: snapshot.error!);
            }
            if (snapshot.data case final report?) {
              return _EvaluationResult(report: report);
            }
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Evaluating 30 fictional questions…'),
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

  final RetrievalQualityReport report;

  @override
  Widget build(BuildContext context) {
    final status = report.embeddingModelStatus;
    final implementation = switch (status) {
      EmbeddingModelAvailable() =>
        '${status.implementation} · ${status.dimensions} dimensions · revision ${status.revision}',
      EmbeddingModelUnavailable() =>
        '${status.implementation} unavailable: ${status.reason}',
      EmbeddingModelUnreported() => 'Embedding implementation unreported',
    };
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Evaluation complete',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(implementation),
        const SizedBox(height: 20),
        _MetricRow(label: 'Hybrid recall@4', metrics: report.hybrid),
        const SizedBox(height: 8),
        _MetricRow(label: 'Dense-only recall@4', metrics: report.denseOnly),
        const SizedBox(height: 20),
        Text(report.decision),
        const SizedBox(height: 20),
        Text(
          'The complete machine-readable report was written to the Flutter console as numbered RETRIEVAL_QUALITY_JSON_PART records.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

final class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.metrics});

  final String label;
  final RetrievalModeMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final percent = (metrics.recallAtFour * 100).toStringAsFixed(1);
    return Text(
      '$label: ${metrics.hits}/${metrics.total} ($percent%)',
      style: Theme.of(context).textTheme.titleMedium,
    );
  }
}

final class _EvaluationFailure extends StatelessWidget {
  const _EvaluationFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    debugPrint('RETRIEVAL_QUALITY_ERROR=${error.runtimeType}');
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Evaluation failed. Check the sanitized Flutter console error marker.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
