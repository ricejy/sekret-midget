import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../platform/embedder.dart';
import '../platform/llm_backend.dart';
import '../platform/ocr_engine.dart';
import '../platform/pdf_page_rasterizer.dart';
import '../platform/pdf_text_extractor.dart';
import '../platform/token_counter.dart';
import '../question/document_question_service.dart';

enum ImportStage {
  extracting,
  ocr,
  chunking,
  embedding,
  indexing,
  complete,
  failed,
  cancelled,
}

enum DocumentSourceType { pastedText, pdf, photo }

enum RetrievalMode { hybrid, denseOnly }

final class RetrievalConfiguration {
  const RetrievalConfiguration({
    required this.targetChunkTokens,
    required this.overlapTokens,
    required this.candidateLimit,
    required this.reciprocalRankConstant,
    required this.contextPassageLimit,
    required this.maximumContextTokens,
    required this.answerTokenReservation,
  });

  final int targetChunkTokens;
  final int overlapTokens;
  final int candidateLimit;
  final int reciprocalRankConstant;
  final int contextPassageLimit;
  final int maximumContextTokens;
  final int answerTokenReservation;
}

const productionRetrievalConfiguration = RetrievalConfiguration(
  targetChunkTokens: 250,
  overlapTokens: 38,
  candidateLimit: 20,
  reciprocalRankConstant: 60,
  contextPassageLimit: 4,
  maximumContextTokens: 4096,
  answerTokenReservation: 512,
);

final class ImportProgress {
  const ImportProgress({required this.stage, this.document, this.message});

  final ImportStage stage;
  final LibraryDocument? document;
  final String? message;
}

final class ImportCancellationController {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

final class LibraryDocument {
  const LibraryDocument({
    required this.id,
    required this.title,
    required this.importedAt,
    required this.sourceType,
    required this.pageCount,
  });

  final String id;
  final String title;
  final DateTime importedAt;
  final DocumentSourceType sourceType;
  final int pageCount;
}

final class RetrievedEvidence {
  const RetrievedEvidence({
    required this.chunkId,
    required this.text,
    required this.heading,
    required this.page,
  });

  final int chunkId;
  final String text;
  final String heading;
  final int? page;

  String get serializedText {
    final serializedHeading = heading.isEmpty ? '' : '$heading\n';
    return '$serializedHeading$text';
  }
}

abstract interface class DocumentLibrary {
  EmbeddingModelStatus get embeddingModelStatus;

  LlmAvailability get llmAvailability;

  Stream<ImportProgress> importPastedText({
    required String title,
    required String text,
    ImportCancellationController? cancellation,
  });

  Stream<ImportProgress> importPdf({
    required String title,
    required String sourceName,
    required Uint8List bytes,
    ImportCancellationController? cancellation,
  });

  Stream<ImportProgress> importPhoto({
    required String title,
    required String sourceName,
    required Uint8List bytes,
    ImportCancellationController? cancellation,
  });

  Future<List<LibraryDocument>> listDocuments();

  Future<List<RetrievedEvidence>> retrieveEvidence({
    required String documentId,
    required String question,
    RetrievalMode mode = RetrievalMode.hybrid,
  });

  Future<DocumentQuestionOutcome> ask({
    required String documentId,
    required String question,
  });

  Stream<DocumentQuestionUpdate> askStream({
    required String documentId,
    required String question,
  });

  Future<LlmAvailability> refreshLlmAvailability();

  Future<void> openModelSettings();

  Future<void> deleteDocument(String documentId);

  Future<void> close();
}

Future<DocumentLibrary> openDocumentLibrary({
  required String databasePath,
  required Embedder embedder,
  required LlmBackend llmBackend,
  required TokenCounter tokenCounter,
  PdfTextExtractor pdfTextExtractor = const UnavailablePdfTextExtractor(),
  PdfPageRasterizer pdfPageRasterizer = const UnavailablePdfPageRasterizer(),
  OcrEngine ocrEngine = const UnavailableOcrEngine(),
}) async {
  final embeddingModelStatus = switch (embedder) {
    EmbeddingCapabilityProbe probe => await probe.embeddingModelStatus(),
    _ => const EmbeddingModelUnreported(),
  };
  final llmAvailability = await llmBackend.availability();
  final database = databasePath == ':memory:'
      ? sqlite3.openInMemory()
      : sqlite3.open(databasePath);
  final library = _SqliteDocumentLibrary(
    database,
    embedder,
    llmBackend,
    tokenCounter,
    pdfTextExtractor,
    pdfPageRasterizer,
    ocrEngine,
    embeddingModelStatus,
    llmAvailability,
  );
  library._createSchema();
  return library;
}

final class _SqliteDocumentLibrary implements DocumentLibrary {
  _SqliteDocumentLibrary(
    this._database,
    this._embedder,
    this._llmBackend,
    this._tokenCounter,
    this._pdfTextExtractor,
    this._pdfPageRasterizer,
    this._ocrEngine,
    this.embeddingModelStatus,
    this._llmAvailability,
  );

  static var _idSequence = 0;

  final Database _database;
  final Embedder _embedder;
  final LlmBackend _llmBackend;
  final TokenCounter _tokenCounter;
  final PdfTextExtractor _pdfTextExtractor;
  final PdfPageRasterizer _pdfPageRasterizer;
  final OcrEngine _ocrEngine;
  @override
  final EmbeddingModelStatus embeddingModelStatus;
  LlmAvailability _llmAvailability;
  @override
  LlmAvailability get llmAvailability => _llmAvailability;
  bool _isClosed = false;

  void _createSchema() {
    _database.execute('PRAGMA foreign_keys = ON;');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_bytes BLOB,
        page_count INTEGER NOT NULL DEFAULT 0,
        imported_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        text TEXT NOT NULL,
        heading TEXT NOT NULL,
        page INTEGER,
        token_count INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS vectors (
        chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
        vector BLOB NOT NULL,
        scale REAL NOT NULL
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        chunk_id UNINDEXED,
        document_id UNINDEXED,
        heading,
        text
      );
    ''');
    final documentColumns = {
      for (final row in _database.select('PRAGMA table_info(documents);'))
        row['name'] as String,
    };
    if (!documentColumns.contains('source_bytes')) {
      _database.execute('ALTER TABLE documents ADD COLUMN source_bytes BLOB;');
    }
    if (!documentColumns.contains('page_count')) {
      _database.execute(
        'ALTER TABLE documents ADD COLUMN page_count INTEGER NOT NULL DEFAULT 0;',
      );
    }
  }

  @override
  Stream<ImportProgress> importPastedText({
    required String title,
    required String text,
    ImportCancellationController? cancellation,
  }) async* {
    _ensureOpen();
    final cleanTitle = title.trim();
    final cleanText = text.trim();
    yield const ImportProgress(stage: ImportStage.extracting);
    if (cleanTitle.isEmpty || cleanText.isEmpty) {
      yield const ImportProgress(
        stage: ImportStage.failed,
        message: 'Enter both a document title and document text.',
      );
      return;
    }
    if (cancellation?.isCancelled ?? false) {
      yield const ImportProgress(
        stage: ImportStage.cancelled,
        message: 'Import cancelled. No document data was saved.',
      );
      return;
    }
    yield* _indexExtractedPages(
      title: cleanTitle,
      sourceType: DocumentSourceType.pastedText,
      sourceBytes: null,
      pages: [_SourcePage(text: cleanText, page: null)],
      cancellation: cancellation,
    );
  }

  @override
  Stream<ImportProgress> importPdf({
    required String title,
    required String sourceName,
    required Uint8List bytes,
    ImportCancellationController? cancellation,
  }) async* {
    _ensureOpen();
    final cleanTitle = title.trim();
    final cleanSourceName = sourceName.trim();
    yield const ImportProgress(stage: ImportStage.extracting);
    if (cleanTitle.isEmpty || cleanSourceName.isEmpty || bytes.isEmpty) {
      yield const ImportProgress(
        stage: ImportStage.failed,
        message: 'Choose a PDF and enter a document title.',
      );
      return;
    }

    try {
      final extracted = await _pdfTextExtractor.extract(
        bytes: bytes,
        sourceName: cleanSourceName,
        isCancelled: () => cancellation?.isCancelled ?? false,
      );
      if (cancellation?.isCancelled ?? false) {
        yield const ImportProgress(
          stage: ImportStage.cancelled,
          message: 'Import cancelled. No document data was saved.',
        );
        return;
      }
      final emptyPageNumbers = [
        for (final page in extracted.pages)
          if (page.text.trim().isEmpty) page.pageNumber,
      ];
      final recognizedPages = <int, OcrRecognition>{};
      var lowConfidence = false;
      if (emptyPageNumbers.isNotEmpty) {
        yield ImportProgress(
          stage: ImportStage.ocr,
          message: emptyPageNumbers.length == extracted.pages.length
              ? 'No text layer was found. Running on-device OCR.'
              : 'Some pages have no text layer. Running on-device OCR.',
        );
        final rasterizedPages = await _pdfPageRasterizer.rasterize(
          bytes: bytes,
          sourceName: cleanSourceName,
          pageNumbers: emptyPageNumbers,
          isCancelled: () => cancellation?.isCancelled ?? false,
        );
        for (var index = 0; index < rasterizedPages.length; index += 1) {
          final rasterized = rasterizedPages[index];
          yield ImportProgress(
            stage: ImportStage.ocr,
            message:
                'Recognizing scanned page ${index + 1} of ${rasterizedPages.length}.',
          );
          final recognition = await _ocrEngine.recognize(
            image: rasterized.image,
            isCancelled: () => cancellation?.isCancelled ?? false,
          );
          if (!_hasUsefulOcrText(recognition.text)) {
            yield const ImportProgress(
              stage: ImportStage.failed,
              message:
                  'OCR found too little readable text. Check the page orientation and image quality, then retry.',
            );
            return;
          }
          lowConfidence =
              lowConfidence || recognition.confidence < _lowOcrConfidence;
          recognizedPages[rasterized.pageNumber] = recognition;
        }
        if (recognizedPages.length != emptyPageNumbers.length ||
            !emptyPageNumbers.every(recognizedPages.containsKey)) {
          yield const ImportProgress(
            stage: ImportStage.failed,
            message:
                'One or more scanned PDF pages could not be recognized. No document data was saved.',
          );
          return;
        }
      }
      final readablePages = [
        for (final page in extracted.pages)
          _SourcePage(
            text: page.text.trim().isNotEmpty
                ? page.text.trim()
                : recognizedPages[page.pageNumber]!.text.trim(),
            page: page.pageNumber,
          ),
      ];
      yield* _indexExtractedPages(
        title: cleanTitle,
        sourceType: DocumentSourceType.pdf,
        sourceBytes: bytes,
        pages: readablePages,
        pageCount: extracted.pages.length,
        cancellation: cancellation,
        completionMessage: lowConfidence
            ? 'Import complete, but OCR confidence was low. Verify the cited source before relying on an answer.'
            : null,
      );
    } on PdfExtractionException catch (error) {
      final cancelled = error.code == PdfExtractionFailureCode.cancelled;
      yield ImportProgress(
        stage: cancelled ? ImportStage.cancelled : ImportStage.failed,
        message: cancelled
            ? 'Import cancelled. No document data was saved.'
            : _pdfImportMessage(error.code),
      );
    } on PdfRasterException catch (error) {
      final cancelled = error.code == PdfRasterFailureCode.cancelled;
      yield ImportProgress(
        stage: cancelled ? ImportStage.cancelled : ImportStage.failed,
        message: cancelled
            ? 'Import cancelled. No document data was saved.'
            : _pdfRasterMessage(error.code),
      );
    } on OcrException catch (error) {
      final cancelled = error.code == OcrFailureCode.cancelled;
      yield ImportProgress(
        stage: cancelled ? ImportStage.cancelled : ImportStage.failed,
        message: cancelled
            ? 'Import cancelled. No document data was saved.'
            : _ocrImportMessage(error.code),
      );
    } on Object {
      yield const ImportProgress(
        stage: ImportStage.failed,
        message:
            'The PDF could not be imported. Choose another file and retry.',
      );
    }
  }

  @override
  Stream<ImportProgress> importPhoto({
    required String title,
    required String sourceName,
    required Uint8List bytes,
    ImportCancellationController? cancellation,
  }) async* {
    _ensureOpen();
    final cleanTitle = title.trim();
    final cleanSourceName = sourceName.trim();
    if (cleanTitle.isEmpty || cleanSourceName.isEmpty || bytes.isEmpty) {
      yield const ImportProgress(
        stage: ImportStage.failed,
        message: 'Choose a document photo and enter a document title.',
      );
      return;
    }
    yield const ImportProgress(
      stage: ImportStage.ocr,
      message: 'Recognizing the document photo on this device.',
    );
    try {
      final recognition = await _ocrEngine.recognize(
        image: OcrImageInput.encoded(bytes),
        isCancelled: () => cancellation?.isCancelled ?? false,
      );
      if (!_hasUsefulOcrText(recognition.text)) {
        yield const ImportProgress(
          stage: ImportStage.failed,
          message:
              'OCR found too little readable text. Retake the photo straight-on in better light, then retry.',
        );
        return;
      }
      yield* _indexExtractedPages(
        title: cleanTitle,
        sourceType: DocumentSourceType.photo,
        sourceBytes: bytes,
        pages: [_SourcePage(text: recognition.text.trim(), page: 1)],
        pageCount: 1,
        cancellation: cancellation,
        completionMessage: recognition.confidence < _lowOcrConfidence
            ? 'Import complete, but OCR confidence was low. Verify the cited source before relying on an answer.'
            : null,
      );
    } on OcrException catch (error) {
      final cancelled = error.code == OcrFailureCode.cancelled;
      yield ImportProgress(
        stage: cancelled ? ImportStage.cancelled : ImportStage.failed,
        message: cancelled
            ? 'Import cancelled. No document data was saved.'
            : _ocrImportMessage(error.code),
      );
    } on Object {
      yield const ImportProgress(
        stage: ImportStage.failed,
        message:
            'The document photo could not be imported. Choose another image and retry.',
      );
    }
  }

  Stream<ImportProgress> _indexExtractedPages({
    required String title,
    required DocumentSourceType sourceType,
    required Uint8List? sourceBytes,
    required List<_SourcePage> pages,
    required ImportCancellationController? cancellation,
    int pageCount = 0,
    String? completionMessage,
  }) async* {
    try {
      yield const ImportProgress(stage: ImportStage.chunking);
      final chunks = await _chunkSourcePages(pages, _tokenCounter);
      if (chunks.isEmpty) {
        yield const ImportProgress(
          stage: ImportStage.failed,
          message: 'No readable document text was found.',
        );
        return;
      }
      if (cancellation?.isCancelled ?? false) {
        yield const ImportProgress(
          stage: ImportStage.cancelled,
          message: 'Import cancelled. No document data was saved.',
        );
        return;
      }

      yield const ImportProgress(stage: ImportStage.embedding);
      final preparedChunks = <_PreparedChunk>[];
      for (final chunk in chunks) {
        if (cancellation?.isCancelled ?? false) {
          yield const ImportProgress(
            stage: ImportStage.cancelled,
            message: 'Import cancelled. No document data was saved.',
          );
          return;
        }
        final embeddedText = chunk.heading.isEmpty
            ? chunk.text
            : '${chunk.heading}\n${chunk.text}';
        final vector = await _embedder.embed(embeddedText);
        final quantized = _quantize(vector);
        preparedChunks.add(
          _PreparedChunk(
            chunk: chunk,
            tokenCount: await _tokenCounter.countTokens(chunk.text),
            vector: quantized.bytes,
            scale: quantized.scale,
          ),
        );
      }

      if (cancellation?.isCancelled ?? false) {
        yield const ImportProgress(
          stage: ImportStage.cancelled,
          message: 'Import cancelled. No document data was saved.',
        );
        return;
      }
      yield const ImportProgress(stage: ImportStage.indexing);
      final document = _persistDocument(
        title,
        preparedChunks,
        sourceType: sourceType,
        sourceBytes: sourceBytes,
        pageCount: pageCount,
      );
      yield ImportProgress(
        stage: ImportStage.complete,
        document: document,
        message: completionMessage,
      );
    } on EmbeddingException catch (error) {
      yield ImportProgress(
        stage: ImportStage.failed,
        message: _embeddingImportMessage(error.code),
      );
    } on Object {
      yield ImportProgress(
        stage: ImportStage.failed,
        message: switch (sourceType) {
          DocumentSourceType.pdf =>
            'The PDF could not be imported. Choose another file and retry.',
          DocumentSourceType.photo =>
            'The document photo could not be imported. Choose another image and retry.',
          DocumentSourceType.pastedText =>
            'The document could not be imported. Check the text and try again.',
        },
      );
    }
  }

  LibraryDocument _persistDocument(
    String title,
    List<_PreparedChunk> chunks, {
    required DocumentSourceType sourceType,
    required Uint8List? sourceBytes,
    required int pageCount,
  }) {
    final importedAt = DateTime.now().toUtc();
    final document = LibraryDocument(
      id: '${importedAt.microsecondsSinceEpoch.toRadixString(36)}-${_idSequence++}',
      title: title,
      importedAt: importedAt,
      sourceType: sourceType,
      pageCount: pageCount,
    );
    _database.execute('BEGIN IMMEDIATE;');
    try {
      _database.execute(
        '''
          INSERT INTO documents
            (id, title, source_type, source_bytes, page_count, imported_at)
          VALUES (?, ?, ?, ?, ?, ?);
        ''',
        [
          document.id,
          document.title,
          _sourceTypeValue(sourceType),
          sourceBytes,
          pageCount,
          importedAt.toIso8601String(),
        ],
      );
      for (var ordinal = 0; ordinal < chunks.length; ordinal += 1) {
        final prepared = chunks[ordinal];
        _database.execute(
          '''
            INSERT INTO chunks
              (document_id, ordinal, text, heading, page, token_count)
            VALUES (?, ?, ?, ?, ?, ?);
          ''',
          [
            document.id,
            ordinal,
            prepared.chunk.text,
            prepared.chunk.heading,
            prepared.chunk.page,
            prepared.tokenCount,
          ],
        );
        final chunkId = _database.lastInsertRowId;
        _database.execute(
          'INSERT INTO vectors (chunk_id, vector, scale) VALUES (?, ?, ?);',
          [chunkId, prepared.vector, prepared.scale],
        );
        _database.execute(
          '''
            INSERT INTO chunks_fts (chunk_id, document_id, heading, text)
            VALUES (?, ?, ?, ?);
          ''',
          [chunkId, document.id, prepared.chunk.heading, prepared.chunk.text],
        );
      }
      _database.execute('COMMIT;');
      return document;
    } on Object {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<List<LibraryDocument>> listDocuments() async {
    _ensureOpen();
    final rows = _database.select('''
      SELECT id, title, source_type, page_count, imported_at
      FROM documents
      ORDER BY imported_at DESC, id DESC;
    ''');
    return [
      for (final row in rows)
        LibraryDocument(
          id: row['id'] as String,
          title: row['title'] as String,
          importedAt: DateTime.parse(row['imported_at'] as String),
          sourceType: _sourceTypeFromValue(row['source_type'] as String),
          pageCount: row['page_count'] as int,
        ),
    ];
  }

  @override
  Future<DocumentQuestionOutcome> ask({
    required String documentId,
    required String question,
  }) async {
    DocumentQuestionOutcome outcome = const InsufficientEvidence();
    await for (final update in askStream(
      documentId: documentId,
      question: question,
    )) {
      if (update case AnswerCompleted(outcome: final completedOutcome)) {
        outcome = completedOutcome;
      }
    }
    return outcome;
  }

  @override
  Stream<DocumentQuestionUpdate> askStream({
    required String documentId,
    required String question,
  }) async* {
    _ensureOpen();
    final cleanQuestion = question.trim();
    if (cleanQuestion.isEmpty || !_documentExists(documentId)) {
      yield const AnswerCompleted(InsufficientEvidence());
      return;
    }

    final List<RetrievedEvidence> admitted;
    try {
      admitted = await retrieveEvidence(
        documentId: documentId,
        question: cleanQuestion,
      );
    } on EmbeddingException catch (error) {
      yield AnswerCompleted(
        RetrievalUnavailable(_embeddingRetrievalMessage(error.code)),
      );
      return;
    }
    if (admitted.isEmpty) {
      yield const AnswerCompleted(InsufficientEvidence());
      return;
    }

    final evidence = admitted
        .map((passage) => passage.serializedText)
        .toList(growable: false);
    final prompt = buildGuardrailV1Prompt(
      question: cleanQuestion,
      evidence: evidence,
    );
    String? streamedAnswer;
    try {
      await for (final snapshot in _llmBackend.generate(
        question: cleanQuestion,
        evidence: evidence,
        prompt: prompt,
      )) {
        final cleanSnapshot = snapshot.trim();
        if (cleanSnapshot.isEmpty) {
          continue;
        }
        streamedAnswer = cleanSnapshot;
        if (_supportingEvidenceIndex(
              cleanSnapshot,
              admitted,
              question: cleanQuestion,
            ) !=
            null) {
          yield AnswerTextUpdate(cleanSnapshot);
        }
      }
    } on LlmException catch (error) {
      yield AnswerCompleted(answerFailureFor(error.code));
      return;
    }
    if (streamedAnswer == null) {
      yield const AnswerCompleted(
        AnswerFailure(
          kind: AnswerFailureKind.streamFailure,
          message: 'The on-device answer stopped before completion. Try again.',
        ),
      );
      return;
    }
    if (streamedAnswer == insufficientEvidenceMessage) {
      yield const AnswerCompleted(InsufficientEvidence());
      return;
    }
    final sourceIndex = _supportingEvidenceIndex(
      streamedAnswer,
      admitted,
      question: cleanQuestion,
    );
    if (sourceIndex == null) {
      yield const AnswerCompleted(InsufficientEvidence());
      return;
    }
    final source = admitted[sourceIndex];
    yield AnswerCompleted(
      GroundedAnswer(
        text: streamedAnswer,
        citation: Citation(
          passage: source.text,
          page: source.page ?? 0,
          heading: source.heading,
        ),
      ),
    );
  }

  @override
  Future<LlmAvailability> refreshLlmAvailability() async {
    _ensureOpen();
    _llmAvailability = await _llmBackend.availability();
    return _llmAvailability;
  }

  @override
  Future<void> openModelSettings() async {
    _ensureOpen();
    if (_llmBackend case final LlmSettingsController controller) {
      await controller.openSettings();
    }
  }

  @override
  Future<List<RetrievedEvidence>> retrieveEvidence({
    required String documentId,
    required String question,
    RetrievalMode mode = RetrievalMode.hybrid,
  }) async {
    _ensureOpen();
    final cleanQuestion = question.trim();
    if (cleanQuestion.isEmpty || !_documentExists(documentId)) {
      return const [];
    }

    final denseRanks = await _denseRanks(documentId, cleanQuestion);
    final rankedIds = switch (mode) {
      RetrievalMode.hybrid => _fuseRanks(
        _lexicalRanks(documentId, cleanQuestion),
        denseRanks,
      ),
      RetrievalMode.denseOnly => denseRanks,
    };
    if (rankedIds.isEmpty) {
      return const [];
    }
    final rankedChunks = _loadChunks(rankedIds);
    final admitted = await _assembleContext(cleanQuestion, rankedChunks);
    return [
      for (final chunk in admitted)
        RetrievedEvidence(
          chunkId: chunk.id,
          text: chunk.text,
          heading: chunk.heading,
          page: chunk.page,
        ),
    ];
  }

  bool _documentExists(String documentId) {
    return _database.select('SELECT 1 FROM documents WHERE id = ? LIMIT 1;', [
      documentId,
    ]).isNotEmpty;
  }

  List<int> _lexicalRanks(String documentId, String question) {
    final query = _ftsQuery(question);
    if (query.isEmpty) {
      return const [];
    }
    final rows = _database.select(
      '''
        SELECT CAST(chunk_id AS INTEGER) AS chunk_id
        FROM chunks_fts
        WHERE chunks_fts MATCH ? AND document_id = ?
        ORDER BY bm25(chunks_fts)
        LIMIT ?;
      ''',
      [query, documentId, productionRetrievalConfiguration.candidateLimit],
    );
    return [for (final row in rows) row['chunk_id'] as int];
  }

  Future<List<int>> _denseRanks(String documentId, String question) async {
    final questionVector = await _embedder.embed(question);
    if (questionVector.isEmpty || questionVector.every((value) => value == 0)) {
      return const [];
    }
    final rows = _database.select(
      '''
        SELECT chunks.id AS chunk_id, vectors.vector, vectors.scale
        FROM chunks
        JOIN vectors ON vectors.chunk_id = chunks.id
        WHERE chunks.document_id = ?;
      ''',
      [documentId],
    );
    final scored = <(int, double)>[];
    for (final row in rows) {
      final bytes = row['vector'] as Uint8List;
      final scale = (row['scale'] as num).toDouble();
      final vector = _dequantize(bytes, scale);
      if (vector.length != questionVector.length) {
        continue;
      }
      final score = _cosineSimilarity(questionVector, vector);
      if (score > 0) {
        scored.add((row['chunk_id'] as int, score));
      }
    }
    scored.sort((left, right) => right.$2.compareTo(left.$2));
    return [
      for (final item in scored.take(
        productionRetrievalConfiguration.candidateLimit,
      ))
        item.$1,
    ];
  }

  List<int> _fuseRanks(List<int> lexical, List<int> dense) {
    final rankConstant =
        productionRetrievalConfiguration.reciprocalRankConstant;
    final scores = <int, double>{};
    for (var index = 0; index < lexical.length; index += 1) {
      scores.update(
        lexical[index],
        (score) => score + 1 / (rankConstant + index + 1),
        ifAbsent: () => 1 / (rankConstant + index + 1),
      );
    }
    for (var index = 0; index < dense.length; index += 1) {
      scores.update(
        dense[index],
        (score) => score + 1 / (rankConstant + index + 1),
        ifAbsent: () => 1 / (rankConstant + index + 1),
      );
    }
    final ranked = scores.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    return [
      for (final entry in ranked.take(
        productionRetrievalConfiguration.candidateLimit,
      ))
        entry.key,
    ];
  }

  List<_StoredChunk> _loadChunks(List<int> rankedIds) {
    if (rankedIds.isEmpty) {
      return const [];
    }
    final placeholders = List.filled(rankedIds.length, '?').join(',');
    final rows = _database.select('''
        SELECT id, text, heading, page, token_count
        FROM chunks
        WHERE id IN ($placeholders);
      ''', rankedIds);
    final chunksById = {
      for (final row in rows)
        row['id'] as int: _StoredChunk(
          id: row['id'] as int,
          text: row['text'] as String,
          heading: row['heading'] as String,
          page: row['page'] as int?,
          tokenCount: row['token_count'] as int,
        ),
    };
    return [for (final id in rankedIds) ?chunksById[id]];
  }

  Future<List<_StoredChunk>> _assembleContext(
    String question,
    List<_StoredChunk> rankedChunks,
  ) async {
    final contextProbe = _tokenCounter is ModelContextProbe
        ? _tokenCounter as ModelContextProbe
        : null;
    final contextLimit = contextProbe == null
        ? productionRetrievalConfiguration.maximumContextTokens
        : await contextProbe.contextWindowSize();
    final instructionTokens = contextProbe == null
        ? await _tokenCounter.countTokens(guardrailV1Instructions)
        : await contextProbe.countInstructionTokens(guardrailV1Instructions);
    final admitted = <_StoredChunk>[];
    for (final chunk in rankedChunks) {
      final candidateEvidence = [
        ...admitted,
        chunk,
      ].map(_serializeChunk).toList(growable: false);
      final candidatePrompt = buildGuardrailV1Prompt(
        question: question,
        evidence: candidateEvidence,
      );
      final promptTokens = contextProbe == null
          ? await _tokenCounter.countTokens(candidatePrompt)
          : await contextProbe.countPromptTokens(candidatePrompt);
      final totalTokens =
          instructionTokens +
          promptTokens +
          productionRetrievalConfiguration.answerTokenReservation;
      if (totalTokens > contextLimit) {
        continue;
      }
      admitted.add(chunk);
      if (admitted.length ==
          productionRetrievalConfiguration.contextPassageLimit) {
        break;
      }
    }
    return admitted;
  }

  String _serializeChunk(_StoredChunk chunk) {
    final heading = chunk.heading.isEmpty ? '' : '${chunk.heading}\n';
    return '$heading${chunk.text}';
  }

  @override
  Future<void> deleteDocument(String documentId) async {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE;');
    try {
      _database.execute('DELETE FROM chunks_fts WHERE document_id = ?;', [
        documentId,
      ]);
      _database.execute('DELETE FROM documents WHERE id = ?;', [documentId]);
      _database.execute('COMMIT;');
    } on Object {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _database.close();
    _isClosed = true;
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('The document library is closed.');
    }
  }
}

int? _supportingEvidenceIndex(
  String answer,
  List<RetrievedEvidence> evidence, {
  required String question,
}) {
  final questionTerms = _attributionTerms(question);
  final answerTerms = _attributionTerms(answer).difference(questionTerms);
  if (answerTerms.isEmpty) {
    return null;
  }
  var bestIndex = 0;
  var bestScore = 0;
  for (var index = 0; index < evidence.length; index += 1) {
    final passageTerms = _attributionTerms(evidence[index].serializedText);
    final score = answerTerms.where(passageTerms.contains).length;
    if (score > bestScore) {
      bestIndex = index;
      bestScore = score;
    }
  }
  return bestScore == 0 ? null : bestIndex;
}

Set<String> _attributionTerms(String text) {
  const ignored = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'by',
    'for',
    'from',
    'in',
    'is',
    'it',
    'of',
    'on',
    'or',
    'that',
    'the',
    'this',
    'to',
    'was',
    'with',
  };
  return {
    for (final match in RegExp(r'[a-z0-9]+').allMatches(text.toLowerCase()))
      if (!ignored.contains(match.group(0))) match.group(0)!,
  };
}

String _embeddingImportMessage(EmbeddingFailureCode code) => switch (code) {
  EmbeddingFailureCode.unavailable =>
    'On-device semantic search is unavailable for English on this device.',
  EmbeddingFailureCode.invalidInput || EmbeddingFailureCode.vectorUnavailable =>
    'Part of this document could not be embedded on this device. Edit the text and try again.',
  EmbeddingFailureCode.dimensionMismatch ||
  EmbeddingFailureCode.bridgeFailure =>
    'On-device semantic search failed. No document data was saved.',
};

String _embeddingRetrievalMessage(EmbeddingFailureCode code) => switch (code) {
  EmbeddingFailureCode.unavailable =>
    'On-device semantic search is unavailable for English on this device.',
  EmbeddingFailureCode.invalidInput || EmbeddingFailureCode.vectorUnavailable =>
    'This question could not be embedded on this device. Edit it and try again.',
  EmbeddingFailureCode.dimensionMismatch ||
  EmbeddingFailureCode.bridgeFailure =>
    'On-device semantic search failed. Try again.',
};

String _pdfImportMessage(PdfExtractionFailureCode code) => switch (code) {
  PdfExtractionFailureCode.passwordProtected =>
    'This PDF is password protected. Remove the password and try again.',
  PdfExtractionFailureCode.malformed =>
    'This PDF is malformed or damaged. Choose another file.',
  PdfExtractionFailureCode.unsupported =>
    'This PDF format is not supported on this device.',
  PdfExtractionFailureCode.cancelled =>
    'Import cancelled. No document data was saved.',
  PdfExtractionFailureCode.extractionFailed =>
    'PDF text extraction failed. Choose another file and retry.',
};

String _pdfRasterMessage(PdfRasterFailureCode code) => switch (code) {
  PdfRasterFailureCode.passwordProtected =>
    'This PDF is password protected. Remove the password and try again.',
  PdfRasterFailureCode.malformed =>
    'This scanned PDF is malformed or damaged. Choose another file.',
  PdfRasterFailureCode.unsupported =>
    'Scanned PDF OCR is not supported on this device.',
  PdfRasterFailureCode.cancelled =>
    'Import cancelled. No document data was saved.',
  PdfRasterFailureCode.renderingFailed =>
    'A scanned PDF page could not be prepared for OCR. Try another file.',
};

String _ocrImportMessage(OcrFailureCode code) => switch (code) {
  OcrFailureCode.unavailable =>
    'On-device text recognition is unavailable on this device.',
  OcrFailureCode.invalidInput =>
    'The selected image could not be sent to on-device OCR.',
  OcrFailureCode.decodeFailed =>
    'The selected image could not be decoded. Choose another image.',
  OcrFailureCode.recognitionFailed =>
    'On-device OCR failed. Check the orientation and image quality, then retry.',
  OcrFailureCode.cancelled => 'Import cancelled. No document data was saved.',
};

const _lowOcrConfidence = 0.55;

bool _hasUsefulOcrText(String text) {
  final cleanText = text.trim();
  return cleanText.length >= 20 &&
      cleanText.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length >=
          4;
}

String _sourceTypeValue(DocumentSourceType sourceType) => switch (sourceType) {
  DocumentSourceType.pastedText => 'pasted-text',
  DocumentSourceType.pdf => 'pdf',
  DocumentSourceType.photo => 'photo',
};

DocumentSourceType _sourceTypeFromValue(String value) => switch (value) {
  'pdf' => DocumentSourceType.pdf,
  'photo' => DocumentSourceType.photo,
  _ => DocumentSourceType.pastedText,
};

final class _SourcePage {
  const _SourcePage({required this.text, required this.page});

  final String text;
  final int? page;
}

final class _TextChunk {
  const _TextChunk({
    required this.text,
    required this.heading,
    required this.page,
  });

  final String text;
  final String heading;
  final int? page;
}

final class _PreparedChunk {
  const _PreparedChunk({
    required this.chunk,
    required this.tokenCount,
    required this.vector,
    required this.scale,
  });

  final _TextChunk chunk;
  final int tokenCount;
  final Uint8List vector;
  final double scale;
}

final class _StoredChunk {
  const _StoredChunk({
    required this.id,
    required this.text,
    required this.heading,
    required this.page,
    required this.tokenCount,
  });

  final int id;
  final String text;
  final String heading;
  final int? page;
  final int tokenCount;
}

final class _QuantizedVector {
  const _QuantizedVector(this.bytes, this.scale);

  final Uint8List bytes;
  final double scale;
}

Future<List<_TextChunk>> _chunkSourcePages(
  List<_SourcePage> pages,
  TokenCounter tokenCounter,
) async {
  final targetTokens = productionRetrievalConfiguration.targetChunkTokens;
  final overlapTokens = productionRetrievalConfiguration.overlapTokens;
  final chunks = <_TextChunk>[];
  for (final sourcePage in pages) {
    final sections = _parseSections(sourcePage.text);
    for (final section in sections) {
      final sentences = <_SentenceUnit>[];
      for (final paragraph in section.paragraphs) {
        final paragraphSentences = paragraph
            .split(RegExp(r'(?<=[.!?;])\s+'))
            .where((sentence) => sentence.trim().isNotEmpty)
            .toList();
        for (var index = 0; index < paragraphSentences.length; index += 1) {
          sentences.add(
            _SentenceUnit(
              text: paragraphSentences[index].trim(),
              startsParagraph: index == 0,
            ),
          );
        }
      }
      final current = <_SentenceUnit>[];
      var currentTokens = 0;
      for (final sentence in sentences) {
        final sentenceTokens = await tokenCounter.countTokens(sentence.text);
        if (current.isNotEmpty &&
            currentTokens + sentenceTokens > targetTokens) {
          chunks.add(
            _TextChunk(
              text: _joinSentences(current),
              heading: section.heading,
              page: sourcePage.page,
            ),
          );
          final overlap = <_SentenceUnit>[];
          var overlapCount = 0;
          for (final prior in current.reversed) {
            final priorTokens = await tokenCounter.countTokens(prior.text);
            if (overlapCount + priorTokens > overlapTokens) {
              if (overlap.isEmpty) {
                overlap.insert(0, prior);
                overlapCount += priorTokens;
              }
              break;
            }
            overlap.insert(0, prior);
            overlapCount += priorTokens;
          }
          current
            ..clear()
            ..addAll(overlap);
          currentTokens = overlapCount;
        }
        current.add(sentence);
        currentTokens += sentenceTokens;
      }
      if (current.isNotEmpty) {
        chunks.add(
          _TextChunk(
            text: _joinSentences(current),
            heading: section.heading,
            page: sourcePage.page,
          ),
        );
      }
    }
  }
  return chunks;
}

final class _SentenceUnit {
  const _SentenceUnit({required this.text, required this.startsParagraph});

  final String text;
  final bool startsParagraph;
}

String _joinSentences(List<_SentenceUnit> sentences) {
  final buffer = StringBuffer();
  for (var index = 0; index < sentences.length; index += 1) {
    final sentence = sentences[index];
    if (index > 0) {
      buffer.write(sentence.startsParagraph ? '\n\n' : ' ');
    }
    buffer.write(sentence.text);
  }
  return buffer.toString();
}

final class _Section {
  const _Section({required this.heading, required this.paragraphs});

  final String heading;
  final List<String> paragraphs;
}

List<_Section> _parseSections(String text) {
  final sections = <_Section>[];
  var heading = '';
  final paragraphs = <String>[];
  final paragraphLines = <String>[];

  void flushParagraph() {
    final paragraph = paragraphLines.join(' ').trim();
    if (paragraph.isNotEmpty) {
      paragraphs.add(paragraph);
      paragraphLines.clear();
    }
  }

  void flushSection() {
    flushParagraph();
    if (paragraphs.isNotEmpty) {
      sections.add(_Section(heading: heading, paragraphs: List.of(paragraphs)));
      paragraphs.clear();
    }
  }

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      flushParagraph();
      continue;
    }
    if (_looksLikeHeading(line)) {
      flushSection();
      heading = line;
    } else {
      paragraphLines.add(line);
    }
  }
  flushSection();
  return sections;
}

bool _looksLikeHeading(String line) {
  if (line.length > 100 || line.endsWith('.') || line.endsWith(';')) {
    return false;
  }
  final letters = line.replaceAll(RegExp('[^A-Za-z]'), '');
  if (letters.length < 3) {
    return false;
  }
  if (letters == letters.toUpperCase()) {
    return true;
  }
  const connectors = {'a', 'an', 'and', 'for', 'of', 'or', 'the', 'to'};
  final words = RegExp(
    '[A-Za-z]+',
  ).allMatches(line).map((match) => match.group(0)!).toList();
  return words.isNotEmpty &&
      words.every(
        (word) =>
            connectors.contains(word) ||
            word.codeUnitAt(0) >= 65 && word.codeUnitAt(0) <= 90,
      );
}

String _ftsQuery(String question) {
  const stopWords = {
    'a',
    'an',
    'and',
    'are',
    'does',
    'how',
    'is',
    'must',
    'the',
    'to',
    'what',
    'when',
    'within',
  };
  final terms = question
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty && !stopWords.contains(term))
      .toSet();
  return terms.map((term) => '"${term.replaceAll('"', '""')}"').join(' OR ');
}

_QuantizedVector _quantize(List<double> vector) {
  if (vector.isEmpty) {
    return _QuantizedVector(Uint8List(0), 1);
  }
  final maximum = vector.fold<double>(
    0,
    (current, value) => math.max(current, value.abs()),
  );
  if (maximum == 0) {
    return _QuantizedVector(Uint8List(vector.length), 1);
  }
  final scale = maximum / 127;
  final bytes = Uint8List(vector.length);
  for (var index = 0; index < vector.length; index += 1) {
    final quantized = (vector[index] / scale).round().clamp(-127, 127);
    bytes[index] = quantized < 0 ? quantized + 256 : quantized;
  }
  return _QuantizedVector(bytes, scale);
}

List<double> _dequantize(Uint8List bytes, double scale) {
  return [for (final byte in bytes) (byte > 127 ? byte - 256 : byte) * scale];
}

double _cosineSimilarity(List<double> left, List<double> right) {
  if (left.length != right.length || left.isEmpty) {
    return 0;
  }
  var dotProduct = 0.0;
  var leftMagnitude = 0.0;
  var rightMagnitude = 0.0;
  for (var index = 0; index < left.length; index += 1) {
    dotProduct += left[index] * right[index];
    leftMagnitude += left[index] * left[index];
    rightMagnitude += right[index] * right[index];
  }
  if (leftMagnitude == 0 || rightMagnitude == 0) {
    return 0;
  }
  return dotProduct / math.sqrt(leftMagnitude * rightMagnitude);
}
