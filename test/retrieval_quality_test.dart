import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/library/document_library.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sekret_midget/evaluation/retrieval_quality.dart';
import 'package:sekret_midget/evaluation/synthetic_retrieval_corpus.dart';

void main() {
  test(
    'the committed corpus is fictional, labeled, and meaningfully grouped',
    () {
      final questions = [
        for (final document in syntheticRetrievalCorpus) ...document.questions,
      ];

      expect(syntheticRetrievalCorpus, hasLength(6));
      expect(questions.length, greaterThanOrEqualTo(30));
      expect(
        questions.map((question) => question.id).toSet(),
        hasLength(questions.length),
      );
      expect(questions.map((question) => question.category).toSet(), {
        'amount',
        'deadline',
        'exact-term',
        'obligation',
        'paraphrase',
      });
      expect(
        syntheticRetrievalCorpus.every(
          (document) => document.title.startsWith('Fictional '),
        ),
        isTrue,
      );
      expect(
        syntheticRetrievalCorpus.map((document) => document.text).join('\n'),
        isNot(contains('@')),
      );
      for (final document in syntheticRetrievalCorpus) {
        for (final question in document.questions) {
          for (final heading in question.relevantHeadings) {
            expect(
              document.text,
              contains(heading),
              reason: '${question.id} must label a heading in ${document.id}',
            );
          }
        }
      }
    },
  );

  test(
    'production retrieval keeps every known relevant passage in top four',
    () async {
      final library = await openDocumentLibrary(
        databasePath: ':memory:',
        embedder: _SyntheticLabelEmbedder(),
        llmBackend: const _UnusedBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(library.close);

      final report = await evaluateRetrievalQuality(
        library: library,
        tokenCounterImplementation: 'Deterministic whitespace counter',
        runAt: DateTime.utc(2026, 8, 25),
      );

      expect(report.results, hasLength(30));
      expect(report.hybrid.hits, 30);
      expect(report.hybrid.recallAtFour, 1);
      expect(report.denseOnly.hits, 30);
      expect(report.denseOnly.recallAtFour, 1);
      expect(
        report.results,
        everyElement(
          isA<RetrievalQuestionEvaluation>()
              .having((result) => result.hybridHit, 'hybrid hit', isTrue)
              .having(
                (result) => result.denseOnlyHit,
                'dense-only hit',
                isTrue,
              ),
        ),
      );
    },
  );

  test(
    'report records the configuration required to reproduce a run',
    () async {
      final library = await openDocumentLibrary(
        databasePath: ':memory:',
        embedder: _SyntheticLabelEmbedder(),
        llmBackend: const _UnusedBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(library.close);

      final report = await evaluateRetrievalQuality(
        library: library,
        tokenCounterImplementation: 'Deterministic whitespace counter',
        runAt: DateTime.utc(2026, 8, 25),
      );
      final json = jsonDecode(report.toPrettyJson()) as Map<String, Object?>;
      final embedding = json['embedding'] as Map<String, Object?>;
      final chunking = json['chunking'] as Map<String, Object?>;
      final ranking = json['ranking'] as Map<String, Object?>;

      expect(json['runAt'], '2026-08-25T00:00:00.000Z');
      expect(json['recallAt4Target'], 0.8);
      expect(
        json['tokenCounterImplementation'],
        'Deterministic whitespace counter',
      );
      expect(embedding['implementation'], 'Synthetic label fake');
      expect(embedding['dimensions'], 30);
      expect(chunking['targetTokens'], 250);
      expect(chunking['overlapTokens'], 38);
      expect(ranking['candidateLimit'], 20);
      expect(ranking['reciprocalRankConstant'], 60);
      expect(ranking['contextPassageLimit'], 4);
    },
  );
}

final class _SyntheticLabelEmbedder
    implements Embedder, EmbeddingCapabilityProbe {
  _SyntheticLabelEmbedder()
    : _headings = {
        for (final document in syntheticRetrievalCorpus)
          for (final question in document.questions)
            for (final heading in question.relevantHeadings) heading,
      }.toList()..sort();

  final List<String> _headings;

  @override
  Future<EmbeddingModelStatus> embeddingModelStatus() async {
    return EmbeddingModelAvailable(
      implementation: 'Synthetic label fake',
      language: 'en',
      dimensions: _headings.length,
      revision: 1,
    );
  }

  @override
  Future<List<double>> embed(String text) async {
    String? selectedHeading;
    for (final heading in _headings) {
      if (text.startsWith('$heading\n')) {
        selectedHeading = heading;
        break;
      }
    }
    if (selectedHeading == null) {
      for (final document in syntheticRetrievalCorpus) {
        for (final question in document.questions) {
          if (text == question.question) {
            selectedHeading = question.relevantHeadings.single;
            break;
          }
        }
        if (selectedHeading != null) {
          break;
        }
      }
    }
    return [
      for (final heading in _headings) heading == selectedHeading ? 1 : 0,
    ];
  }
}

final class _UnusedBackend implements LlmBackend {
  const _UnusedBackend();

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) {
    throw StateError('Retrieval evaluation must not invoke generation.');
  }
}
