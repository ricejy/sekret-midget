import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/library/document_library.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/core/platform/pdf_text_extractor.dart';
import 'package:sekret_midget/core/platform/token_counter.dart';
import 'package:sekret_midget/core/question/document_question_service.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'reports the active embedding implementation and runtime shape',
    () async {
      final library = await openDocumentLibrary(
        databasePath: ':memory:',
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(library.close);

      expect(
        library.embeddingModelStatus,
        isA<EmbeddingModelAvailable>()
            .having(
              (status) => status.implementation,
              'implementation',
              'Deterministic fake',
            )
            .having((status) => status.dimensions, 'dimensions', 5)
            .having((status) => status.revision, 'revision', 1),
      );
    },
  );

  test(
    'upgrades an existing pasted-text library without losing documents',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-schema-upgrade-',
      );
      final databasePath =
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3';
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final legacyDatabase = sqlite3.open(databasePath);
      legacyDatabase.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source_type TEXT NOT NULL,
        imported_at TEXT NOT NULL
      );
    ''');
      legacyDatabase.execute(
        '''
        INSERT INTO documents (id, title, source_type, imported_at)
        VALUES (?, ?, ?, ?);
      ''',
        [
          'legacy-document',
          'Fictional legacy policy',
          'pasted-text',
          '2026-08-01T00:00:00.000Z',
        ],
      );
      legacyDatabase.close();

      final library = await openDocumentLibrary(
        databasePath: databasePath,
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      final documents = await library.listDocuments();
      await library.close();

      expect(documents, hasLength(1));
      expect(documents.single.id, 'legacy-document');
      expect(documents.single.sourceType, DocumentSourceType.pastedText);
      expect(documents.single.pageCount, 0);

      final upgradedDatabase = sqlite3.open(databasePath);
      addTearDown(upgradedDatabase.close);
      final columns = {
        for (final row in upgradedDatabase.select(
          'PRAGMA table_info(documents);',
        ))
          row['name'] as String,
      };
      expect(columns, containsAll(<String>['source_bytes', 'page_count']));
    },
  );

  test(
    'persists every chunk vector with a bounded quantized round trip',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-quantization-',
      );
      final databasePath =
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3';
      final library = await openDocumentLibrary(
        databasePath: databasePath,
        embedder: const _KnownVectorEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });

      final progress = await library
          .importPastedText(
            title: 'Fictional two-section policy',
            text: '''
FIRST SECTION

The first fictional rule applies.

SECOND SECTION

The second fictional rule applies.
''',
          )
          .toList();
      await library.close();

      final database = sqlite3.open(databasePath);
      addTearDown(database.close);
      final rows = database.select('''
      SELECT chunks.id, chunks.ordinal, vectors.chunk_id, vectors.vector, vectors.scale
      FROM chunks
      JOIN vectors ON vectors.chunk_id = chunks.id
      ORDER BY chunks.ordinal;
    ''');

      expect(progress.last.stage, ImportStage.complete);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['chunk_id'], row['id']);
        final bytes = row['vector'] as List<int>;
        final scale = (row['scale'] as num).toDouble();
        final restored = [
          for (final byte in bytes) (byte > 127 ? byte - 256 : byte) * scale,
        ];
        expect(restored, hasLength(_KnownVectorEmbedder.vector.length));
        for (var index = 0; index < restored.length; index += 1) {
          expect(
            restored[index],
            closeTo(_KnownVectorEmbedder.vector[index], scale / 2 + 1e-12),
          );
        }
      }
    },
  );

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

  test(
    'PDF import persists its source and preserves page citations through deletion',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'sekret-midget-pdf-library-',
      );
      final databasePath =
          '${temporaryDirectory.path}${Platform.pathSeparator}library.sqlite3';
      final fixtureBytes = await File(
        'test/fixtures/fictional_text_contract.pdf',
      ).readAsBytes();
      var library = await openDocumentLibrary(
        databasePath: databasePath,
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
        pdfTextExtractor: const _FixturePdfExtractor(),
      );
      addTearDown(() async {
        await library.close();
        await temporaryDirectory.delete(recursive: true);
      });

      final progress = await library
          .importPdf(
            title: 'Fictional Meridian Employment Agreement',
            sourceName: 'fictional_text_contract.pdf',
            bytes: fixtureBytes,
          )
          .toList();
      final document = (await library.listDocuments()).single;
      final outcome = await library.ask(
        documentId: document.id,
        question: 'How much advance warning is required to end employment?',
      );
      await library.close();

      final persisted = sqlite3.open(databasePath);
      final sourceRow = persisted.select('''
        SELECT source_type, length(source_bytes) AS source_size, page_count
        FROM documents;
      ''').single;
      final noticeChunk = persisted.select('''
        SELECT heading, page, text
        FROM chunks
        WHERE heading = 'NOTICE PERIOD';
      ''').single;
      persisted.close();

      expect(progress.map((event) => event.stage), [
        ImportStage.extracting,
        ImportStage.chunking,
        ImportStage.embedding,
        ImportStage.indexing,
        ImportStage.complete,
      ]);
      expect(document.sourceType, DocumentSourceType.pdf);
      expect(document.pageCount, 3);
      expect(sourceRow['source_type'], 'pdf');
      expect(sourceRow['source_size'], fixtureBytes.length);
      expect(sourceRow['page_count'], 3);
      expect(noticeChunk['page'], 2);
      expect(noticeChunk['text'], contains('forty-five calendar days'));
      expect(
        outcome,
        isA<GroundedAnswer>()
            .having((answer) => answer.citation.page, 'page', 2)
            .having(
              (answer) => answer.citation.heading,
              'heading',
              'NOTICE PERIOD',
            ),
      );

      library = await openDocumentLibrary(
        databasePath: databasePath,
        embedder: const FakeEmbedder(),
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
        pdfTextExtractor: const _FixturePdfExtractor(),
      );
      await library
          .importPdf(
            title: 'Fictional Meridian Employment Agreement',
            sourceName: 'fictional_text_contract.pdf',
            bytes: fixtureBytes,
          )
          .drain<void>();
      final reimportedDocuments = await library.listDocuments();
      expect(reimportedDocuments, hasLength(2));
      for (final importedDocument in reimportedDocuments) {
        await library.deleteDocument(importedDocument.id);
      }
      await library.close();

      final deleted = sqlite3.open(databasePath);
      addTearDown(deleted.close);
      expect(
        deleted
            .select('SELECT COUNT(*) AS count FROM documents;')
            .single['count'],
        0,
      );
      expect(
        deleted.select('SELECT COUNT(*) AS count FROM chunks;').single['count'],
        0,
      );
      expect(
        deleted
            .select('SELECT COUNT(*) AS count FROM vectors;')
            .single['count'],
        0,
      );
      expect(
        deleted
            .select('SELECT COUNT(*) AS count FROM chunks_fts;')
            .single['count'],
        0,
      );
    },
  );

  test('an empty PDF text layer requires OCR and persists nothing', () async {
    final library = await openDocumentLibrary(
      databasePath: ':memory:',
      embedder: const FakeEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
      pdfTextExtractor: const _EmptyPdfExtractor(),
    );
    addTearDown(library.close);

    final progress = await library
        .importPdf(
          title: 'Fictional scanned PDF',
          sourceName: 'scanned.pdf',
          bytes: Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
        )
        .toList();

    expect(progress.last.stage, ImportStage.failed);
    expect(progress.last.message, contains('requires on-device OCR'));
    expect(await library.listDocuments(), isEmpty);
  });

  test(
    'a malformed or cancelled PDF leaves no queryable partial data',
    () async {
      for (final (extractor, cancellation, expectedStage) in [
        (
          const _FailingPdfExtractor(PdfExtractionFailureCode.malformed),
          null,
          ImportStage.failed,
        ),
        (
          const _FailingPdfExtractor(PdfExtractionFailureCode.cancelled),
          ImportCancellationController()..cancel(),
          ImportStage.cancelled,
        ),
      ]) {
        final library = await openDocumentLibrary(
          databasePath: ':memory:',
          embedder: const FakeEmbedder(),
          llmBackend: const FakeLlmBackend(),
          tokenCounter: const FakeTokenCounter(),
          pdfTextExtractor: extractor,
        );
        final progress = await library
            .importPdf(
              title: 'Fictional PDF',
              sourceName: 'fixture.pdf',
              bytes: Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
              cancellation: cancellation,
            )
            .toList();

        expect(progress.last.stage, expectedStage);
        expect(await library.listDocuments(), isEmpty);
        await library.close();
      }
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
    'an embedding failure has an explicit message and a retry can recover',
    () async {
      final embedder = _RecoveringEmbedder();
      final library = await openDocumentLibrary(
        databasePath: ':memory:',
        embedder: embedder,
        llmBackend: const FakeLlmBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(library.close);

      final failed = await library
          .importPastedText(
            title: 'Private draft',
            text: 'PRIVATE MARKER 42 must never appear in an error message.',
          )
          .toList();
      embedder.shouldFail = false;
      final recovered = await library
          .importPastedText(
            title: 'Recovered draft',
            text: 'A fictional incident must be reported within fourteen days.',
          )
          .toList();

      expect(failed.last.stage, ImportStage.failed);
      expect(
        failed.last.message,
        'On-device semantic search is unavailable for English on this device.',
      );
      expect(failed.last.message, isNot(contains('PRIVATE MARKER 42')));
      expect(recovered.last.stage, ImportStage.complete);
      expect((await library.listDocuments()).single.title, 'Recovered draft');
    },
  );

  test('a question embedding failure returns a recoverable outcome', () async {
    final embedder = _RecoveringEmbedder()..shouldFail = false;
    final library = await openDocumentLibrary(
      databasePath: ':memory:',
      embedder: embedder,
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(library.close);
    await library
        .importPastedText(
          title: 'Fictional safety policy',
          text: 'INCIDENTS\n\nReport every fictional workplace incident.',
        )
        .drain<void>();
    final document = (await library.listDocuments()).single;
    embedder.shouldFail = true;

    final outcome = await library.ask(
      documentId: document.id,
      question: 'When is an incident due?',
    );

    expect(
      outcome,
      isA<RetrievalUnavailable>().having(
        (result) => result.message,
        'message',
        'On-device semantic search is unavailable for English on this device.',
      ),
    );
  });

  test('generation failures map to explicit portable outcomes', () async {
    for (final (code, expectedKind) in [
      (LlmFailureCode.unavailable, AnswerFailureKind.modelUnavailable),
      (LlmFailureCode.contextOverflow, AnswerFailureKind.contextOverflow),
      (LlmFailureCode.guardrailViolation, AnswerFailureKind.guardrailViolation),
      (LlmFailureCode.streamFailure, AnswerFailureKind.streamFailure),
    ]) {
      final library = await openDocumentLibrary(
        databasePath: ':memory:',
        embedder: const FakeEmbedder(),
        llmBackend: _ThrowingLlmBackend(code),
        tokenCounter: const FakeTokenCounter(),
      );
      await library
          .importPastedText(
            title: 'Fictional safety policy',
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
      await library.close();

      expect(
        outcome,
        isA<AnswerFailure>()
            .having((failure) => failure.kind, 'kind', expectedKind)
            .having(
              (failure) => failure.message,
              'sanitized message',
              isNot(contains('PRIVATE')),
            ),
      );
    }
  });

  test(
    'an unsupported generated claim is normalized to exact abstention',
    () async {
      final library = await openDocumentLibrary(
        databasePath: ':memory:',
        embedder: const FakeEmbedder(),
        llmBackend: const _UnsupportedClaimBackend(),
        tokenCounter: const FakeTokenCounter(),
      );
      addTearDown(library.close);
      await library
          .importPastedText(
            title: 'Fictional employment agreement',
            text: '''
NOTICE PERIOD

Either fictional party may end employment with forty-five days of written notice.
''',
          )
          .drain<void>();
      final document = (await library.listDocuments()).single;

      final updates = await library
          .askStream(
            documentId: document.id,
            question:
                'What color is the manager’s car under the notice period?',
          )
          .toList();

      expect(updates.whereType<AnswerTextUpdate>(), isEmpty);
      expect(
        updates.whereType<AnswerCompleted>().single.outcome,
        isA<InsufficientEvidence>().having(
          (outcome) => outcome.message,
          'message',
          insufficientEvidenceMessage,
        ),
      );
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

final class _KnownVectorEmbedder implements Embedder {
  const _KnownVectorEmbedder();

  static const vector = <double>[0.25, -0.5, 1];

  @override
  Future<List<double>> embed(String text) async => vector;
}

final class _RecoveringEmbedder implements Embedder {
  bool shouldFail = true;

  @override
  Future<List<double>> embed(String text) async {
    if (shouldFail) {
      throw const EmbeddingException(
        EmbeddingFailureCode.unavailable,
        'PRIVATE NATIVE DETAIL',
      );
    }
    return const [1, 0, 0];
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
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) async* {
    yield 'The incident deadline is fourteen days.';
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
    if (text.contains('<document_excerpt>\nINCIDENT REPORTING\n')) {
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
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) {
    throw StateError('The backend must not receive an oversized chunk.');
  }
}

final class _ThrowingLlmBackend implements LlmBackend {
  const _ThrowingLlmBackend(this.code);

  final LlmFailureCode code;

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) async* {
    throw LlmException(code, 'PRIVATE NATIVE DETAIL');
  }
}

final class _UnsupportedClaimBackend implements LlmBackend {
  const _UnsupportedClaimBackend();

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) async* {
    yield 'The manager’s car is blue.';
  }
}

final class _FixturePdfExtractor implements PdfTextExtractor {
  const _FixturePdfExtractor();

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) async {
    return const ExtractedPdf(
      pages: [
        ExtractedPdfPage(
          pageNumber: 1,
          text: 'FICTIONAL MERIDIAN EMPLOYMENT AGREEMENT',
        ),
        ExtractedPdfPage(
          pageNumber: 2,
          text: '''
NOTICE PERIOD

4.2 Either fictional party may end employment by providing forty-five calendar days of written notice.

EFFECTIVE DATE

5.1 This fictional agreement begins on the first Monday of the next lunar quarter.
''',
        ),
        ExtractedPdfPage(
          pageNumber: 3,
          text: '''
COMPENSATION DATE

6.1 The fictional monthly salary is paid on the tenth business day of each month.
''',
        ),
      ],
    );
  }
}

final class _EmptyPdfExtractor implements PdfTextExtractor {
  const _EmptyPdfExtractor();

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) async {
    return const ExtractedPdf(
      pages: [ExtractedPdfPage(pageNumber: 1, text: '')],
    );
  }
}

final class _FailingPdfExtractor implements PdfTextExtractor {
  const _FailingPdfExtractor(this.code);

  final PdfExtractionFailureCode code;

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) {
    throw PdfExtractionException(code, 'PRIVATE EXTRACTOR DETAIL');
  }
}
