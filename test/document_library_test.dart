import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/library/document_library.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/core/platform/token_counter.dart';
import 'package:sekret_midget/core/question/document_question_service.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';

void main() {
  test(
    'pasted text becomes a selectable document with a grounded answer',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-library-',
      );
      final databasePath =
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3';
      final library = await openDocumentLibrary(
        databasePath: databasePath,
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });

      final progress = await library
          .importPastedText(
            title: 'Fictional Orion Safety Policy',
            text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days. The report must identify the date, location, and people involved.

EQUIPMENT

Protective equipment remains the property of Orion Workshop and must be returned when employment ends.
''',
          )
          .toList();
      final documents = await library.listDocuments();
      final outcome = await library.ask(
        documentId: documents.single.id,
        question: 'How soon must an employee report an incident?',
      );

      expect(progress.map((event) => event.stage), [
        ImportStage.extracting,
        ImportStage.chunking,
        ImportStage.embedding,
        ImportStage.indexing,
        ImportStage.complete,
      ]);
      expect(documents.single.title, 'Fictional Orion Safety Policy');
      expect(
        outcome,
        isA<GroundedAnswer>()
            .having(
              (answer) => answer.text,
              'answer',
              'An employee must report an incident within 14 calendar days.',
            )
            .having(
              (answer) => answer.citation.heading,
              'source heading',
              'INCIDENT REPORTING',
            )
            .having(
              (answer) => answer.citation.passage,
              'source passage',
              contains('within 14 calendar days'),
            ),
      );
    },
  );

  test(
    'a paraphrased question can retrieve evidence without shared terms',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-semantic-',
      );
      final library = await openDocumentLibrary(
        databasePath:
            '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });
      await library
          .importPastedText(
            title: 'Fictional Orion Safety Policy',
            text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''',
          )
          .drain<void>();
      final document = (await library.listDocuments()).single;

      final outcome = await library.ask(
        documentId: document.id,
        question: 'How quickly should an accident be disclosed?',
      );

      expect(
        outcome,
        isA<GroundedAnswer>().having(
          (answer) => answer.text,
          'answer',
          'An employee must report an incident within 14 calendar days.',
        ),
      );
    },
  );

  test('an exact-term question can retrieve evidence without vectors', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-lexical-',
    );
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: const _ZeroEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await library
        .importPastedText(
          title: 'Fictional Orion Safety Policy',
          text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''',
        )
        .drain<void>();
    final document = (await library.listDocuments()).single;

    final outcome = await library.ask(
      documentId: document.id,
      question: 'When is an incident report due?',
    );

    expect(outcome, isA<GroundedAnswer>());
  });

  test('a mixed-topic document answers the topic in the question', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-mixed-topic-',
    );
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: const _ConstantEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await library
        .importPastedText(
          title: 'Fictional mixed policy',
          text: '''
TERMINATION

Either party may end employment by giving 30 days' written notice.

INCIDENT REPORTING

Employees must report a workplace incident within 14 calendar days.
''',
        )
        .drain<void>();
    final document = (await library.listDocuments()).single;

    final outcome = await library.ask(
      documentId: document.id,
      question: 'When must an incident be reported?',
    );

    expect(
      outcome,
      isA<GroundedAnswer>().having(
        (answer) => answer.text,
        'answer',
        'An employee must report an incident within 14 calendar days.',
      ),
    );
  });

  test('the citation identifies the chunk that supports the answer', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-citation-source-',
    );
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: const _CitationEmbedder(),
      llmBackend: const _LaterChunkBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await library
        .importPastedText(
          title: 'Fictional two-clause policy',
          text: '''
ACCESS CODE

The workshop access code is cobalt.

INCIDENT DEADLINE

The incident deadline is fourteen days.
''',
        )
        .drain<void>();
    final document = (await library.listDocuments()).single;

    final outcome = await library.ask(
      documentId: document.id,
      question: 'What are the access code and the incident deadline?',
    );

    expect(
      outcome,
      isA<GroundedAnswer>()
          .having(
            (answer) => answer.text,
            'answer',
            'The incident deadline is fourteen days.',
          )
          .having(
            (answer) => answer.citation.heading,
            'supporting heading',
            'INCIDENT DEADLINE',
          )
          .having(
            (answer) => answer.citation.passage,
            'supporting passage',
            contains('fourteen days'),
          ),
    );
  });

  test(
    'a numbered title-case clause is preserved as citation metadata',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-title-case-heading-',
      );
      final library = await openDocumentLibrary(
        databasePath:
            '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });
      await library
          .importPastedText(
            title: 'Fictional employment agreement',
            text: '''
12. Termination

Either party may end employment by giving 30 days' written notice.
''',
          )
          .drain<void>();
      final document = (await library.listDocuments()).single;

      final outcome = await library.ask(
        documentId: document.id,
        question: 'What notice is required to end employment?',
      );

      expect(
        outcome,
        isA<GroundedAnswer>().having(
          (answer) => answer.citation.heading,
          'heading',
          '12. Termination',
        ),
      );
    },
  );

  test('citation text preserves paragraph boundaries from the import', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-paragraphs-',
    );
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: const FakeEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await library
        .importPastedText(
          title: 'Fictional paragraph policy',
          text: '''
INCIDENT REPORTING

Employees must report a workplace incident within 14 calendar days.

The report must identify the date, location, and people involved.
''',
        )
        .drain<void>();
    final document = (await library.listDocuments()).single;

    final outcome = await library.ask(
      documentId: document.id,
      question: 'When must an incident be reported?',
    );

    expect(
      outcome,
      isA<GroundedAnswer>().having(
        (answer) => answer.citation.passage,
        'passage',
        contains('14 calendar days.\n\nThe report must identify'),
      ),
    );
  });

  test('chunk boundaries use the injected model token counter', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-token-chunks-',
    );
    final embedder = _RecordingEmbedder();
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: embedder,
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const _SentenceBudgetTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });

    await library
        .importPastedText(
          title: 'Fictional token policy',
          text: '''
REPORTING RULES

First compact clause covers workplace incident reports. Second compact clause covers the reporting deadline.
''',
        )
        .drain<void>();

    expect(embedder.inputs, hasLength(2));
    expect(embedder.inputs, everyElement(startsWith('REPORTING RULES\n')));
  });

  test('documents and retrieval data survive a library restart', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-restart-',
    );
    final databasePath =
        '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3';
    var library = await openDocumentLibrary(
      databasePath: databasePath,
      embedder: const FakeEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await library
        .importPastedText(
          title: 'Fictional Orion Safety Policy',
          text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''',
        )
        .drain<void>();
    await library.close();

    library = await openDocumentLibrary(
      databasePath: databasePath,
      embedder: const FakeEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    final documents = await library.listDocuments();
    final outcome = await library.ask(
      documentId: documents.single.id,
      question: 'When is an incident report due?',
    );

    expect(documents.single.title, 'Fictional Orion Safety Policy');
    expect(
      outcome,
      isA<GroundedAnswer>().having(
        (answer) => answer.citation.heading,
        'source heading',
        'INCIDENT REPORTING',
      ),
    );
  });

  test('a long trailing sentence is retained as chunk overlap', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-overlap-',
    );
    final embedder = _RecordingEmbedder();
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: embedder,
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const _OverlapTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });

    await library
        .importPastedText(
          title: 'Fictional overlap policy',
          text: '''
REPORTING RULES

Alpha sentence establishes the initial rule. Bridge sentence carries essential cross-boundary context. Final sentence supplies the deadline.
''',
        )
        .drain<void>();

    expect(embedder.inputs, hasLength(2));
    expect(
      embedder.inputs.last,
      contains('Bridge sentence carries essential cross-boundary context.'),
    );
  });

  test('deleting one document leaves another document queryable', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'sekret-midget-delete-',
    );
    final library = await openDocumentLibrary(
      databasePath:
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
      embedder: const FakeEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(() async {
      await library.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await library
        .importPastedText(
          title: 'Policy to delete',
          text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''',
        )
        .drain<void>();
    await library
        .importPastedText(
          title: 'Policy to keep',
          text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''',
        )
        .drain<void>();
    final beforeDelete = await library.listDocuments();
    final deleted = beforeDelete.singleWhere(
      (document) => document.title == 'Policy to delete',
    );
    final kept = beforeDelete.singleWhere(
      (document) => document.title == 'Policy to keep',
    );

    await library.deleteDocument(deleted.id);
    final afterDelete = await library.listDocuments();
    final deletedOutcome = await library.ask(
      documentId: deleted.id,
      question: 'When is an incident report due?',
    );
    final keptOutcome = await library.ask(
      documentId: kept.id,
      question: 'When is an incident report due?',
    );

    expect(afterDelete.map((document) => document.title), ['Policy to keep']);
    expect(deletedOutcome, isA<InsufficientEvidence>());
    expect(keptOutcome, isA<GroundedAnswer>());
  });

  test(
    'an import failure is recoverable without exposing pasted text',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-failure-',
      );
      final library = await openDocumentLibrary(
        databasePath:
            '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
        embedder: const _FailingEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });

      final progress = await library
          .importPastedText(
            title: 'Private draft',
            text: 'PRIVATE MARKER 42 must never appear in an error message.',
          )
          .toList();

      expect(progress.last.stage, ImportStage.failed);
      expect(progress.last.message, isNot(contains('PRIVATE MARKER 42')));
      expect(await library.listDocuments(), isEmpty);
    },
  );

  test(
    'a chunk is excluded whole when it cannot fit the context budget',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-context-',
      );
      final library = await openDocumentLibrary(
        databasePath:
            '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
        embedder: const FakeEmbedder(),
        llmBackend: const _FailIfCalledBackend(),
        tokenCounter: const _OversizedEvidenceTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });
      await library
          .importPastedText(
            title: 'Fictional oversized policy',
            text: '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''',
          )
          .drain<void>();
      final document = (await library.listDocuments()).single;

      final outcome = await library.ask(
        documentId: document.id,
        question: 'When is an incident report due?',
      );

      expect(outcome, isA<InsufficientEvidence>());
    },
  );

  test(
    'context budgeting includes serialized headings and separators',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-serialized-context-',
      );
      final library = await openDocumentLibrary(
        databasePath:
            '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3',
        embedder: const FakeEmbedder(),
        llmBackend: const _FailIfCalledBackend(),
        tokenCounter: const _HeadingSensitiveTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });
      await library
          .importPastedText(
            title: 'Fictional heading-heavy policy',
            text: '''
INCIDENT REPORTING

Employees must report a workplace incident within 14 calendar days.
''',
          )
          .drain<void>();
      final document = (await library.listDocuments()).single;

      final outcome = await library.ask(
        documentId: document.id,
        question: 'When must an incident be reported?',
      );

      expect(outcome, isA<InsufficientEvidence>());
    },
  );
}

final class _FailingEmbedder implements Embedder {
  const _FailingEmbedder();

  @override
  Future<List<double>> embed(String text) {
    throw StateError('Could not embed: $text');
  }
}

final class _ZeroEmbedder implements Embedder {
  const _ZeroEmbedder();

  @override
  Future<List<double>> embed(String text) async => const [0, 0, 0, 0];
}

final class _ConstantEmbedder implements Embedder {
  const _ConstantEmbedder();

  @override
  Future<List<double>> embed(String text) async => const [1];
}

final class _CitationEmbedder implements Embedder {
  const _CitationEmbedder();

  @override
  Future<List<double>> embed(String text) async {
    final normalized = text.toLowerCase();
    if (normalized.contains('access') && normalized.contains('deadline')) {
      return const [1, 0.2];
    }
    if (normalized.contains('deadline') || normalized.contains('fourteen')) {
      return const [0, 1];
    }
    if (normalized.contains('access') || normalized.contains('cobalt')) {
      return const [1, 0];
    }
    return const [0, 0];
  }
}

final class _LaterChunkBackend implements LlmBackend {
  const _LaterChunkBackend();

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Future<GeneratedAnswer> generate({
    required String question,
    required List<String> evidence,
  }) async {
    return const GeneratedAnswer(
      text: 'The incident deadline is fourteen days.',
      supportingEvidenceIndex: 1,
    );
  }
}

final class _RecordingEmbedder implements Embedder {
  final inputs = <String>[];

  @override
  Future<List<double>> embed(String text) async {
    inputs.add(text);
    return const [1, 0, 0, 0];
  }
}

final class _SentenceBudgetTokenCounter implements TokenCounter {
  const _SentenceBudgetTokenCounter();

  @override
  Future<int> countTokens(String text) async {
    if (text.contains('First compact clause') &&
        text.contains('Second compact clause')) {
      return 280;
    }
    if (text.contains('compact clause')) {
      return 140;
    }
    return 10;
  }
}

final class _OverlapTokenCounter implements TokenCounter {
  const _OverlapTokenCounter();

  @override
  Future<int> countTokens(String text) async {
    var count = 0;
    if (text.contains('Alpha sentence')) {
      count += 120;
    }
    if (text.contains('Bridge sentence')) {
      count += 120;
    }
    if (text.contains('Final sentence')) {
      count += 40;
    }
    return count == 0 ? 10 : count;
  }
}

final class _OversizedEvidenceTokenCounter implements TokenCounter {
  const _OversizedEvidenceTokenCounter();

  @override
  Future<int> countTokens(String text) async {
    return text.contains('Employees must report') ? 4000 : 10;
  }
}

final class _HeadingSensitiveTokenCounter implements TokenCounter {
  const _HeadingSensitiveTokenCounter();

  @override
  Future<int> countTokens(String text) async {
    if (text.startsWith('INCIDENT REPORTING\n')) {
      return 3600;
    }
    if (text.contains('Employees must report')) {
      return 3400;
    }
    return 10;
  }
}

final class _FailIfCalledBackend implements LlmBackend {
  const _FailIfCalledBackend();

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Future<GeneratedAnswer> generate({
    required String question,
    required List<String> evidence,
  }) {
    throw StateError('The backend must not receive an oversized chunk.');
  }
}
