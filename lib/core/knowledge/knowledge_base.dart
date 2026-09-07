import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../platform/embedder.dart';
import '../platform/ocr_engine.dart';
import '../platform/pdf_page_rasterizer.dart';
import '../platform/pdf_text_extractor.dart';
import '../platform/token_counter.dart';
import '../storage/local_data_vault.dart';
import 'knowledge_algorithms.dart';

final class KnowledgeImportResult {
  const KnowledgeImportResult(this.item, {required this.duplicate});
  final KnowledgeItemRecord item;
  final bool duplicate;
}

final class KnowledgeLocation {
  const KnowledgeLocation(this.itemId, {this.page, this.text});
  final String itemId;
  final int? page;
  final String? text;
}

final class CatalogueMatch {
  const CatalogueMatch(this.item, {this.location, this.excerpt});
  final KnowledgeItemRecord item;
  final KnowledgeLocation? location;
  final String? excerpt;
}

final class KnowledgePreview {
  const KnowledgePreview({
    required this.item,
    required this.source,
    required this.location,
  });
  final KnowledgeItemRecord item;
  final KnowledgeSource source;
  final KnowledgeLocation location;
  bool get hasOcrWarning => source.pages.any(
    (page) => page.ocrConfidence != null && page.ocrConfidence! < 0.55,
  );
}

/// Owns v2 ingestion, recovery, catalogue, preview and indexed evidence. The
/// caller owns the vault and disposes this module before closing the vault.
/// Subscribe to changes before importing. Import returns once the original is
/// retained; process(id) can also be awaited to observe terminal processing.
final class KnowledgeBase {
  KnowledgeBase._(
    this._store,
    this._embedder,
    this._tokens,
    this._pdfLoader,
    this._rasterizer,
    this._ocr,
  );

  static Future<KnowledgeBase> open({
    required LocalDataVault vault,
    required Embedder embedder,
    required TokenCounter tokenCounter,
    PdfTextDocumentLoader? pdfLoader,
    PdfPageRasterizer rasterizer = const UnavailablePdfPageRasterizer(),
    OcrEngine ocr = const UnavailableOcrEngine(),
  }) async {
    final base = KnowledgeBase._(
      vault.knowledge,
      embedder,
      tokenCounter,
      pdfLoader,
      rasterizer,
      ocr,
    );
    // A process death can leave processing records, but never a partial index.
    for (final item in await base._store.list()) {
      if (item.processingState == KnowledgeProcessingState.processing) {
        await base._store.setState(item.id, KnowledgeProcessingState.paused);
      }
    }
    return base;
  }

  final VaultKnowledge _store;
  final Embedder _embedder;
  final TokenCounter _tokens;
  final PdfTextDocumentLoader? _pdfLoader;
  final PdfPageRasterizer _rasterizer;
  final OcrEngine _ocr;
  final _changes = StreamController<void>.broadcast();
  final _jobs = <String, _ProcessingJob>{};
  Future<void> _writes = Future.value();
  bool _foreground = true;
  bool _disposed = false;
  Stream<void> get changes => _changes.stream;

  void _ensureOpen() {
    if (_disposed) throw StateError('Knowledge Base is closed.');
  }

  void _notify() {
    if (!_disposed) _changes.add(null);
  }

  Future<T> _write<T>(Future<T> Function() action) {
    _ensureOpen();
    final result = _writes.then((_) => action());
    _writes = result.then<void>(
      (_) => _notify(),
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<KnowledgeImportResult> importText({
    required String title,
    required String text,
  }) => importSource(
    title: title,
    sourceType: KnowledgeSourceType.pastedText,
    bytes: Uint8List.fromList(utf8.encode(text)),
  );

  Future<KnowledgeImportResult> importSource({
    required String title,
    required KnowledgeSourceType sourceType,
    required Uint8List bytes,
    String? sourceName,
  }) {
    final retained = Uint8List.fromList(bytes);
    return _write(() async {
      if (!_foreground) throw StateError('Return to the app before importing.');
      if (title.trim().isEmpty || retained.isEmpty) {
        throw ArgumentError('Choose content and enter a title.');
      }
      final fingerprintBytes = sourceType == KnowledgeSourceType.pastedText
          ? utf8.encode(
              utf8.decode(retained).trim().replaceAll(RegExp(r'\s+'), ' '),
            )
          : retained;
      if (fingerprintBytes.isEmpty) throw ArgumentError('Enter some text.');
      final fingerprint =
          '${sourceType.name}:${sha256.convert(fingerprintBytes)}';
      for (final item in await _store.list()) {
        if (item.fingerprint == fingerprint) {
          return KnowledgeImportResult(item, duplicate: true);
        }
      }
      final item = await _store.beginProcessing(
        title: title.trim(),
        sourceType: sourceType,
        sourceBytes: retained,
        sourceName: sourceName,
        fingerprint: fingerprint,
      );
      _backgroundProcess(item.id);
      return KnowledgeImportResult(item, duplicate: false);
    });
  }

  void _backgroundProcess(String id) {
    unawaited(
      process(id).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!_disposed) _changes.addError(error, stack);
        },
      ),
    );
  }

  /// Retry or resume; successful items are unchanged. Re-indexing is explicit
  /// through invalidateIndex, which makes the old index ineligible immediately.
  Future<KnowledgeItemRecord> process(String id) {
    _ensureOpen();
    if (!_foreground) {
      return Future.error(StateError('Processing requires the foreground.'));
    }
    final existing = _jobs[id];
    if (existing != null) return existing.done.future;
    final job = _ProcessingJob();
    _jobs[id] = job;
    unawaited(
      _process(id, job).then(
        (item) {
          _jobs.remove(id);
          job.done.complete(item);
        },
        onError: (Object error, StackTrace stack) {
          _jobs.remove(id);
          job.done.completeError(error, stack);
        },
      ),
    );
    return job.done.future;
  }

  Future<KnowledgeItemRecord> _process(String id, _ProcessingJob job) async {
    var item = await _store.get(id);
    if (item.processingState == KnowledgeProcessingState.indexed) return item;
    await _store.setState(
      id,
      KnowledgeProcessingState.processing,
      reset: item.processingState == KnowledgeProcessingState.needsReindexing,
    );
    _notify();
    PdfTextDocument? document;
    try {
      job.check();
      final original = await _store.source(id);
      final pages = <KnowledgePage>[...original.pages];
      int total;
      if (item.sourceType == KnowledgeSourceType.pdf) {
        if (_pdfLoader == null) {
          throw const _ProcessingFailure('PDF extraction is unavailable.');
        }
        document = await _pdfLoader.open(
          bytes: original.bytes,
          sourceName: item.sourceName ?? item.title,
        );
        job.check();
        total = document.pageCount;
      } else {
        total = 1;
      }
      if (total < 1) {
        throw const _ProcessingFailure('No readable pages were found.');
      }
      for (var number = 1; number <= total; number++) {
        job.check();
        if (pages.any((page) => page.number == number)) continue;
        await _checkpoint(id, 'extracting', pages.length, total);
        String text;
        double? confidence;
        switch (item.sourceType) {
          case KnowledgeSourceType.pastedText:
            text = utf8.decode(original.bytes).trim();
          case KnowledgeSourceType.photo:
            final recognition = await _ocr.recognize(
              image: OcrImageInput.encoded(original.bytes),
              isCancelled: () => job.paused,
            );
            text = recognition.text.trim();
            confidence = recognition.confidence;
          case KnowledgeSourceType.pdf:
            text = (await document!.loadPageText(number)).trim();
            job.check();
            if (text.isEmpty) {
              await _checkpoint(id, 'ocr', pages.length, total);
              final rendered = await _rasterizer.rasterize(
                bytes: original.bytes,
                sourceName: item.sourceName ?? item.title,
                pageNumbers: [number],
                isCancelled: () => job.paused,
              );
              job.check();
              if (rendered.length != 1 ||
                  rendered.single.pageNumber != number) {
                throw const _ProcessingFailure(
                  'The scanned page could not be rendered.',
                );
              }
              final recognition = await _ocr.recognize(
                image: rendered.single.image,
                isCancelled: () => job.paused,
              );
              text = recognition.text.trim();
              confidence = recognition.confidence;
            }
        }
        job.check();
        if (confidence != null &&
            (text.length < 20 || text.split(RegExp(r'\s+')).length < 4)) {
          throw const _ProcessingFailure(
            'Not enough readable text was recognized. Check image quality and retry.',
          );
        }
        final page = KnowledgePage(
          number: number,
          text: text,
          ocrConfidence: confidence,
        );
        await _store.savePage(id, page, total);
        pages.add(page);
        await _checkpoint(id, 'extracting', pages.length, total);
      }
      pages.sort((a, b) => a.number.compareTo(b.number));
      // Release the PDF handle before embedding; no rendered page or native PDF
      // object is retained across the indexing phase.
      final extractedDocument = document;
      document = null;
      await extractedDocument?.dispose();
      job.check();
      await _checkpoint(id, 'chunking', 0, pages.length);
      final chunks = await chunkSourcePages([
        for (final page in pages)
          SourcePage(
            text: page.text,
            page: item.sourceType == KnowledgeSourceType.pastedText
                ? null
                : page.number,
          ),
      ], _ProcessingTokens(_tokens, job));
      if (chunks.isEmpty) {
        throw const _ProcessingFailure('No readable document text was found.');
      }
      final passages = <EvidencePassageDraft>[];
      int? dimensions;
      for (final chunk in chunks) {
        job.check();
        await _checkpoint(id, 'embedding', passages.length, chunks.length);
        final vector = await _embedder.embed(
          chunk.heading.isEmpty
              ? chunk.text
              : '${chunk.heading}\n${chunk.text}',
        );
        job.check();
        if (vector.isEmpty ||
            vector.any((v) => !v.isFinite) ||
            vector.every((v) => v == 0) ||
            (dimensions != null && dimensions != vector.length)) {
          throw const _ProcessingFailure(
            'On-device semantic indexing returned an invalid vector. Retry indexing.',
          );
        }
        dimensions = vector.length;
        final quantized = quantize(vector);
        final count = await _tokens.countTokens(chunk.text);
        job.check();
        if (count <= 0) {
          throw const _ProcessingFailure(
            'Text could not be measured for indexing.',
          );
        }
        passages.add(
          EvidencePassageDraft(
            ordinal: passages.length,
            text: chunk.text,
            heading: chunk.heading,
            page: chunk.page,
            tokenCount: count,
            vector: quantized.bytes,
            vectorScale: quantized.scale,
          ),
        );
      }
      await _checkpoint(id, 'indexing', passages.length, passages.length);
      job.check();
      await _store.completeIndex(
        knowledgeItemId: id,
        extractedText: pages.map((page) => page.text).join('\n\n'),
        pageCount: total,
        passages: passages,
      );
    } on Object catch (error) {
      await _store.setState(
        id,
        job.paused
            ? KnowledgeProcessingState.paused
            : KnowledgeProcessingState.failed,
        message: job.paused ? null : _safeFailure(error),
      );
    } finally {
      try {
        await document?.dispose();
      } on Object {
        // Extraction already has a typed terminal outcome. Cleanup failure
        // must not hide it or leave the processing future unresolved.
      }
      _notify();
    }
    return _store.get(id);
  }

  Future<void> _checkpoint(
    String id,
    String stage,
    int completed,
    int total,
  ) async {
    await _store.saveCheckpoint(
      knowledgeItemId: id,
      stage: stage,
      completedUnits: completed,
      totalUnits: total,
      artifact: Uint8List(0),
    );
    _notify();
  }

  Future<void> suspend() async {
    _ensureOpen();
    _foreground = false;
    await _writes;
    final jobs = _jobs.values.toList();
    for (final job in jobs) {
      job.paused = true;
    }
    await Future.wait(jobs.map((job) => job.done.future));
  }

  Future<void> resume() async {
    _ensureOpen();
    _foreground = true;
    for (final item in await _store.list()) {
      if (!_foreground) break;
      if (item.processingState == KnowledgeProcessingState.paused ||
          item.processingState == KnowledgeProcessingState.processing) {
        await process(item.id);
      }
    }
  }

  Future<void> invalidateIndex(String id) async {
    _ensureOpen();
    final job = _jobs[id];
    if (job != null) {
      job.paused = true;
      await job.done.future;
    }
    await _store.setState(id, KnowledgeProcessingState.needsReindexing);
    _notify();
  }

  /// Caller presents action-time confirmation that retained chats are not erased.
  Future<void> delete(String id) => _write(() async {
    final job = _jobs[id];
    if (job != null) {
      job.paused = true;
      await job.done.future;
    }
    await _store.delete(id);
  });

  /// Explicit cancellation discards an incomplete source and every derivative.
  Future<void> cancelImport(String id) => _write(() async {
    final job = _jobs[id];
    if (job != null) {
      job.paused = true;
      await job.done.future;
    }
    if ((await _store.get(id)).processingState ==
        KnowledgeProcessingState.indexed) {
      throw StateError('Use confirmed deletion for indexed knowledge.');
    }
    await _store.delete(id);
  });

  Future<void> rename(String id, String title) =>
      _write(() => _store.rename(id, title));

  Future<List<CatalogueMatch>> catalogue({
    String query = '',
    KnowledgeSourceType? sourceType,
    KnowledgeProcessingState? state,
  }) async {
    _ensureOpen();
    final needle = query.trim().toLowerCase();
    final matches = <CatalogueMatch>[];
    for (final item in await _store.list()) {
      if ((sourceType != null && item.sourceType != sourceType) ||
          (state != null && item.processingState != state)) {
        continue;
      }
      if (needle.isEmpty) {
        matches.add(CatalogueMatch(item));
        continue;
      }
      final pages = await _store.pages(item.id);
      KnowledgePage? match;
      for (final page in pages) {
        if (page.text.toLowerCase().contains(needle)) {
          match = page;
          break;
        }
      }
      if (match != null) {
        final offset = match.text.toLowerCase().indexOf(needle);
        final start = (offset - 40).clamp(0, match.text.length);
        final end = (offset + needle.length + 80).clamp(
          start,
          match.text.length,
        );
        matches.add(
          CatalogueMatch(
            item,
            location: KnowledgeLocation(
              item.id,
              page: match.number,
              text: query.trim(),
            ),
            excerpt: match.text.substring(start, end),
          ),
        );
      } else if (item.title.toLowerCase().contains(needle) ||
          (item.sourceName?.toLowerCase().contains(needle) ?? false)) {
        matches.add(CatalogueMatch(item));
      }
    }
    return List.unmodifiable(matches);
  }

  Future<KnowledgePreview?> preview(KnowledgeLocation location) async {
    _ensureOpen();
    final items = await _store.list();
    if (!items.any((item) => item.id == location.itemId)) return null;
    final item = items.firstWhere((item) => item.id == location.itemId);
    final source = await _store.source(item.id);
    if (location.page != null &&
        (location.page! < 1 || location.page! > item.pageCount)) {
      throw ArgumentError('Page is not available.');
    }
    return KnowledgePreview(item: item, source: source, location: location);
  }

  /// Re-resolves current source availability; a stale citation cannot resurrect
  /// deleted bytes. Its retained evidence text is never treated as a new source.
  Future<KnowledgePreview?> resolveCitation(TurnEvidenceSnapshot evidence) =>
      preview(
        KnowledgeLocation(
          evidence.sourceId,
          page: evidence.page,
          text: evidence.passageText,
        ),
      );

  Future<List<StoredEvidencePassage>> retrieve({
    required String itemId,
    required String question,
    RetrievalMode mode = RetrievalMode.hybrid,
  }) async {
    _ensureOpen();
    if (question.trim().isEmpty) return [];
    final initial = await _store.listIndexedEvidence(itemId);
    if (initial.isEmpty) return [];
    final vector = await _embedder.embed(question);
    if (vector.isEmpty || vector.any((v) => !v.isFinite)) {
      throw const EmbeddingException(
        EmbeddingFailureCode.vectorUnavailable,
        'The question could not be embedded.',
      );
    }
    // Re-read after native work: cancellation/deletion/re-indexing may have run.
    final passages = await _store.listIndexedEvidence(itemId);
    final scored = <(int, double)>[];
    for (final passage in passages) {
      if (passage.vector == null) continue;
      final score = cosineSimilarity(
        vector,
        dequantize(passage.vector!, passage.vectorScale),
      );
      if (score > 0) scored.add((passage.id, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final dense = scored
        .take(productionRetrievalConfiguration.candidateLimit)
        .map((e) => e.$1)
        .toList();
    final lexical = mode == RetrievalMode.hybrid
        ? await _store.lexicalRanks(
            itemId,
            ftsQuery(question),
            productionRetrievalConfiguration.candidateLimit,
          )
        : <int>[];
    final ranked = mode == RetrievalMode.hybrid
        ? fuseRanks(lexical, dense)
        : dense;
    return [
      for (final id in ranked.take(
        productionRetrievalConfiguration.contextPassageLimit,
      ))
        passages.firstWhere((passage) => passage.id == id),
    ];
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await suspend();
    _disposed = true;
    await _changes.close();
  }
}

final class _ProcessingJob {
  bool paused = false;
  final done = Completer<KnowledgeItemRecord>();
  void check() {
    if (paused) throw const _ProcessingFailure('Processing paused.');
  }
}

/// A long document stops between individual native token counts on suspension.
final class _ProcessingTokens implements TokenCounter {
  const _ProcessingTokens(this.delegate, this.job);
  final TokenCounter delegate;
  final _ProcessingJob job;
  @override
  Future<int> countTokens(String text) async {
    job.check();
    final count = await delegate.countTokens(text);
    job.check();
    return count;
  }
}

final class _ProcessingFailure implements Exception {
  const _ProcessingFailure(this.message);
  final String message;
}

String _safeFailure(Object error) => switch (error) {
  _ProcessingFailure() => error.message,
  PdfExtractionException(code: PdfExtractionFailureCode.passwordProtected) =>
    'This PDF is password protected. Remove its password and retry.',
  PdfExtractionException() =>
    'The PDF could not be read. Check the source and retry.',
  PdfRasterException() =>
    'The scanned page could not be rendered. Retry processing.',
  OcrException() =>
    'On-device text recognition failed. Check image quality and retry.',
  EmbeddingException() =>
    'On-device semantic indexing is unavailable or failed. Retry processing.',
  _ =>
    'Processing failed. The original source is retained; retry or delete this item.',
};
