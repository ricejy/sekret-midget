import 'dart:convert';

import '../core/library/document_library.dart';
import '../core/platform/embedder.dart';
import 'synthetic_retrieval_corpus.dart';

const recallAtFourTarget = 0.80;

final class RetrievalQuestionEvaluation {
  const RetrievalQuestionEvaluation({
    required this.documentId,
    required this.questionId,
    required this.category,
    required this.relevantHeadings,
    required this.hybridHeadings,
    required this.denseOnlyHeadings,
  });

  final String documentId;
  final String questionId;
  final String category;
  final Set<String> relevantHeadings;
  final List<String> hybridHeadings;
  final List<String> denseOnlyHeadings;

  bool get hybridHit => hybridHeadings.any(relevantHeadings.contains);
  bool get denseOnlyHit => denseOnlyHeadings.any(relevantHeadings.contains);

  Map<String, Object> toJson() => {
    'documentId': documentId,
    'questionId': questionId,
    'category': category,
    'relevantHeadings': relevantHeadings.toList()..sort(),
    'hybrid': {'hit': hybridHit, 'headings': hybridHeadings},
    'denseOnly': {'hit': denseOnlyHit, 'headings': denseOnlyHeadings},
  };
}

final class RetrievalModeMetrics {
  const RetrievalModeMetrics({
    required this.hits,
    required this.total,
    required this.byCategory,
  });

  final int hits;
  final int total;
  final Map<String, ({int hits, int total})> byCategory;

  double get recallAtFour => total == 0 ? 0 : hits / total;

  Map<String, Object> toJson() => {
    'hits': hits,
    'total': total,
    'recallAt4': recallAtFour,
    'byCategory': {
      for (final entry in byCategory.entries)
        entry.key: {
          'hits': entry.value.hits,
          'total': entry.value.total,
          'recallAt4': entry.value.total == 0
              ? 0
              : entry.value.hits / entry.value.total,
        },
    },
  };
}

final class RetrievalQualityReport {
  const RetrievalQualityReport({
    required this.runAt,
    required this.embeddingModelStatus,
    required this.tokenCounterImplementation,
    required this.results,
  });

  final DateTime runAt;
  final EmbeddingModelStatus embeddingModelStatus;
  final String tokenCounterImplementation;
  final List<RetrievalQuestionEvaluation> results;

  RetrievalModeMetrics get hybrid => _metrics((result) => result.hybridHit);
  RetrievalModeMetrics get denseOnly =>
      _metrics((result) => result.denseOnlyHit);

  String get decision {
    if (embeddingModelStatus is! EmbeddingModelAvailable) {
      return 'Gather more evidence: the production embedding model was not available.';
    }
    if (hybrid.recallAtFour >= recallAtFourTarget) {
      return 'Retain the measured embedding implementation; hybrid recall@4 meets the target.';
    }
    return 'Investigate the identified fallback embedder; hybrid recall@4 is below the target.';
  }

  Map<String, Object> toJson() {
    final status = embeddingModelStatus;
    final embedding = switch (status) {
      EmbeddingModelAvailable() => <String, Object>{
        'available': true,
        'implementation': status.implementation,
        'language': status.language,
        'dimensions': status.dimensions,
        'revision': status.revision,
      },
      EmbeddingModelUnavailable() => <String, Object>{
        'available': false,
        'implementation': status.implementation,
        'language': status.language,
        'reason': status.reason,
      },
      EmbeddingModelUnreported() => <String, Object>{
        'available': false,
        'implementation': 'unreported',
      },
    };
    const configuration = productionRetrievalConfiguration;
    return {
      'schemaVersion': 1,
      'runAt': runAt.toUtc().toIso8601String(),
      'corpus': {
        'name': 'synthetic-contract-and-policy-v1',
        'documents': syntheticRetrievalCorpus.length,
        'questions': results.length,
        'containsRealPersonalData': false,
      },
      'embedding': embedding,
      'tokenCounterImplementation': tokenCounterImplementation,
      'chunking': {
        'targetTokens': configuration.targetChunkTokens,
        'overlapTokens': configuration.overlapTokens,
        'boundaryPolicy': 'sections, paragraphs, and whole sentences',
        'headingPrependedForEmbedding': true,
      },
      'ranking': {
        'candidateLimit': configuration.candidateLimit,
        'reciprocalRankConstant': configuration.reciprocalRankConstant,
        'contextPassageLimit': configuration.contextPassageLimit,
        'hybrid':
            'SQLite FTS5/BM25 plus dense cosine with reciprocal-rank fusion',
        'denseOnly': 'dense cosine',
      },
      'context': {
        'maximumTokens': configuration.maximumContextTokens,
        'answerReservationTokens': configuration.answerTokenReservation,
      },
      'recallAt4Target': recallAtFourTarget,
      'hybrid': hybrid.toJson(),
      'denseOnly': denseOnly.toJson(),
      'decision': decision,
      'questions': [for (final result in results) result.toJson()],
    };
  }

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  RetrievalModeMetrics _metrics(
    bool Function(RetrievalQuestionEvaluation result) isHit,
  ) {
    final categories = <String, ({int hits, int total})>{};
    var hits = 0;
    for (final result in results) {
      final hit = isHit(result);
      if (hit) {
        hits += 1;
      }
      final current = categories[result.category] ?? (hits: 0, total: 0);
      categories[result.category] = (
        hits: current.hits + (hit ? 1 : 0),
        total: current.total + 1,
      );
    }
    return RetrievalModeMetrics(
      hits: hits,
      total: results.length,
      byCategory: Map.unmodifiable(categories),
    );
  }
}

Future<RetrievalQualityReport> evaluateRetrievalQuality({
  required DocumentLibrary library,
  required String tokenCounterImplementation,
  DateTime? runAt,
}) async {
  final results = <RetrievalQuestionEvaluation>[];
  for (final fixture in syntheticRetrievalCorpus) {
    final importProgress = await library
        .importPastedText(title: fixture.title, text: fixture.text)
        .toList();
    final completion = importProgress.last;
    if (completion.stage != ImportStage.complete ||
        completion.document == null) {
      throw StateError(
        'Synthetic fixture ${fixture.id} failed to import: ${completion.message ?? 'unknown failure'}',
      );
    }
    final documentId = completion.document!.id;
    for (final fixtureQuestion in fixture.questions) {
      final hybrid = await library.retrieveEvidence(
        documentId: documentId,
        question: fixtureQuestion.question,
      );
      final denseOnly = await library.retrieveEvidence(
        documentId: documentId,
        question: fixtureQuestion.question,
        mode: RetrievalMode.denseOnly,
      );
      results.add(
        RetrievalQuestionEvaluation(
          documentId: fixture.id,
          questionId: fixtureQuestion.id,
          category: fixtureQuestion.category,
          relevantHeadings: fixtureQuestion.relevantHeadings,
          hybridHeadings: [for (final passage in hybrid) passage.heading],
          denseOnlyHeadings: [for (final passage in denseOnly) passage.heading],
        ),
      );
    }
  }
  return RetrievalQualityReport(
    runAt: runAt ?? DateTime.now().toUtc(),
    embeddingModelStatus: library.embeddingModelStatus,
    tokenCounterImplementation: tokenCounterImplementation,
    results: List.unmodifiable(results),
  );
}
