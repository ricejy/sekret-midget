import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/knowledge/knowledge_base.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/ocr_engine.dart';
import 'package:sekret_midget/core/platform/pdf_page_rasterizer.dart';
import 'package:sekret_midget/core/platform/pdf_text_extractor.dart';
import 'package:sekret_midget/core/platform/token_counter.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late LocalDataVault vault;
  late KnowledgeBase base;
  late TestEmbedder embedder;
  late TestPdfLoader pdf;
  late TestRasterizer rasterizer;
  late TestOcr ocr;
  final temporaryDirectories = <Directory>[];
  Future<KnowledgeBase> open() => KnowledgeBase.open(
    vault: vault,
    embedder: embedder,
    tokenCounter: const FakeTokenCounter(),
    pdfLoader: pdf,
    rasterizer: rasterizer,
    ocr: ocr,
  );
  setUp(() async {
    vault = await openLocalDataVault(databasePath: ':memory:');
    embedder = TestEmbedder();
    pdf = TestPdfLoader();
    rasterizer = TestRasterizer();
    ocr = TestOcr();
    base = await open();
  });
  tearDown(() async {
    await base.dispose();
    await vault.close();
    for (final directory in temporaryDirectories) {
      await directory.delete(recursive: true);
    }
    temporaryDirectories.clear();
  });
  Future<KnowledgeItemRecord> text(
    String content, {
    String title = 'Same title',
  }) async {
    final imported = await base.importText(title: title, text: content);
    return base.process(imported.item.id);
  }

  Future<KnowledgeImportResult> importPdf() => base.importSource(
    title: 'Fictional PDF',
    sourceType: KnowledgeSourceType.pdf,
    bytes: Uint8List.fromList([1, 2, 3]),
    sourceName: 'fixture.pdf',
  );

  test(
    'suspension stops long chunking between individual token counts',
    () async {
      await base.dispose();
      final tokens = GatedTokens();
      base = await KnowledgeBase.open(
        vault: vault,
        embedder: embedder,
        tokenCounter: tokens,
      );
      final imported = await base.importText(
        title: 'Long text',
        text:
            'First fictional sentence. Second fictional sentence. Third fictional sentence.',
      );
      await tokens.entered.future;
      final paused = base.suspend();
      await Future<void>.delayed(Duration.zero);
      tokens.gate.complete();
      await paused;
      expect(tokens.calls, 1);
      expect(
        (await base.catalogue()).single.item.processingState,
        KnowledgeProcessingState.paused,
      );
      await base.resume();
      expect(
        (await base.process(imported.item.id)).processingState,
        KnowledgeProcessingState.indexed,
      );
    },
  );

  test(
    'imports retain originals, index text, and return location-aware previews',
    () async {
      final item = await text(
        'RETURN POLICY\nPlease return the fictional camera within seven days.',
      );
      expect(item.processingState, KnowledgeProcessingState.indexed);
      expect(item.sourceSize, greaterThan(0));
      expect(item.checkpoint, isNull);
      final results = await base.retrieve(
        itemId: item.id,
        question: 'When is the camera returned?',
      );
      expect(results.single.heading, 'RETURN POLICY');
      expect(results.single.page, isNull);
      final matches = await base.catalogue(query: 'camera');
      expect(matches.single.excerpt, contains('seven days'));
      expect(matches.single.location!.page, 1);
      final preview = (await base.preview(matches.single.location!))!;
      expect(preview.source.pages.single.text, contains('RETURN POLICY'));
      expect(String.fromCharCodes(preview.source.bytes), contains('camera'));
      await base.rename(item.id, 'Travel policy');
      expect(
        (await base.catalogue(query: 'Travel')).single.item.title,
        'Travel policy',
      );
      expect(
        await base.catalogue(sourceType: KnowledgeSourceType.photo),
        isEmpty,
      );
      expect(
        await base.catalogue(state: KnowledgeProcessingState.indexed),
        hasLength(1),
      );
      expect(await base.catalogue(query: '%'), isEmpty);
    },
  );

  test(
    'duplicates are content-based, normalized, and do not re-index',
    () async {
      final first = await text('The fictional deadline is seven days.');
      final count = embedder.calls;
      final duplicate = await base.importText(
        title: 'Different name',
        text: '  The fictional\ndeadline is seven   days.  ',
      );
      expect(duplicate.duplicate, isTrue);
      expect(duplicate.item.id, first.id);
      expect(embedder.calls, count);
      final second = await text('The fictional deadline is ten days.');
      expect(second.id, isNot(first.id));
      final imported = await importPdf();
      await base.process(imported.item.id);
      final duplicatePdf = await importPdf();
      expect(duplicatePdf.duplicate, isTrue);
      expect(pdf.opens, 1);
      final parallel = await Future.wait([
        base.importText(
          title: 'A',
          text: 'Identical content from concurrent imports.',
        ),
        base.importText(
          title: 'B',
          text: 'Identical content from concurrent imports.',
        ),
      ]);
      expect(parallel.map((r) => r.item.id).toSet(), hasLength(1));
      expect(parallel.where((r) => r.duplicate), hasLength(1));
    },
  );

  test(
    'partial extraction/embedding is never evidence; paused pages resume safely',
    () async {
      pdf.pages = [
        'FIRST PAGE\nThe fictional first deadline is seven days.',
        'SECOND PAGE\nThe fictional second deadline is ten days.',
      ];
      pdf.gatedPage = 2;
      pdf.gate = Completer<void>();
      final imported = await importPdf();
      final pending = base.process(imported.item.id);
      await pdf.entered.future;
      expect(
        await base.retrieve(itemId: imported.item.id, question: 'deadline'),
        isEmpty,
      );
      expect(
        (await base.catalogue(query: 'first deadline')).single.location!.page,
        1,
      );
      final paused = base.suspend();
      await Future<void>.delayed(Duration.zero);
      pdf.gate!.complete();
      await paused;
      expect((await pending).processingState, KnowledgeProcessingState.paused);
      expect(
        (await vault.knowledge.source(imported.item.id)).pages,
        hasLength(1),
      );
      expect(pdf.disposals, 1);
      pdf.gate = null;
      await base.resume();
      expect(pdf.loaded, [1, 2, 2]);
      expect(
        (await base.catalogue()).single.item.processingState,
        KnowledgeProcessingState.indexed,
      );
      expect(pdf.disposals, 2);
    },
  );

  test(
    'mixed PDFs OCR only missing text layers and retain warnings/page locations',
    () async {
      pdf.pages = [
        'TEXT PAGE\nThe first fictional page has a readable layer.',
        '',
      ];
      final imported = await importPdf();
      final item = await base.process(imported.item.id);
      expect(item.processingState, KnowledgeProcessingState.indexed);
      expect(rasterizer.requested, [2]);
      expect(ocr.calls, 1);
      final match = (await base.catalogue(query: 'recognized')).single;
      expect(match.location!.page, 2);
      final preview = (await base.preview(match.location!))!;
      expect(preview.source.bytes, [1, 2, 3]);
      expect(preview.hasOcrWarning, isTrue);
      expect(preview.source.pages.last.ocrConfidence, 0.4);
    },
  );

  test(
    'photos preserve original bytes, duplicate detection and OCR preview',
    () async {
      final bytes = Uint8List.fromList([4, 5, 6]);
      final imported = await base.importSource(
        title: 'Photo',
        sourceType: KnowledgeSourceType.photo,
        bytes: bytes,
      );
      bytes[0] = 99;
      expect(
        (await base.process(imported.item.id)).processingState,
        KnowledgeProcessingState.indexed,
      );
      final preview = (await base.preview(
        KnowledgeLocation(imported.item.id),
      ))!;
      expect(preview.source.bytes, [4, 5, 6]);
      expect(preview.source.pages.single.text, contains('recognized'));
      final duplicate = await base.importSource(
        title: 'Again',
        sourceType: KnowledgeSourceType.photo,
        bytes: Uint8List.fromList([4, 5, 6]),
      );
      expect(duplicate.duplicate, isTrue);
      expect(ocr.calls, 1);
    },
  );

  test(
    'failed OCR remains retryable and does not expose native details',
    () async {
      ocr.fail = true;
      final imported = await base.importSource(
        title: 'Photo',
        sourceType: KnowledgeSourceType.photo,
        bytes: Uint8List.fromList([4]),
      );
      final failed = await base.process(imported.item.id);
      expect(failed.processingState, KnowledgeProcessingState.failed);
      expect(failed.processingMessage, isNot(contains('PRIVATE')));
      expect(
        await base.retrieve(itemId: failed.id, question: 'Anything'),
        isEmpty,
      );
      expect((await base.preview(KnowledgeLocation(failed.id)))!.source.bytes, [
        4,
      ]);
      ocr.fail = false;
      expect(
        (await base.process(failed.id)).processingState,
        KnowledgeProcessingState.indexed,
      );
    },
  );

  test(
    'short OCR and password-protected PDF failures have recoverable outcomes',
    () async {
      ocr.text = 'No';
      final photo = await base.importSource(
        title: 'Photo',
        sourceType: KnowledgeSourceType.photo,
        bytes: Uint8List.fromList([8]),
      );
      expect(
        (await base.process(photo.item.id)).processingState,
        KnowledgeProcessingState.failed,
      );
      pdf.failOpen = true;
      final imported = await importPdf();
      final failed = await base.process(imported.item.id);
      expect(failed.processingMessage, contains('password'));
      pdf.failOpen = false;
      expect(
        (await base.process(failed.id)).processingState,
        KnowledgeProcessingState.indexed,
      );
    },
  );

  test(
    'explicit cancellation during embedding discards every incomplete derivative',
    () async {
      embedder.gate = Completer<void>();
      final imported = await base.importText(
        title: 'Discard',
        text: 'Private fictional draft with enough words.',
      );
      final pending = base.process(imported.item.id);
      await embedder.entered.future;
      expect(
        await base.retrieve(itemId: imported.item.id, question: 'draft'),
        isEmpty,
      );
      final cancel = base.cancelImport(imported.item.id);
      await Future<void>.delayed(Duration.zero);
      embedder.gate!.complete();
      await cancel;
      await pending;
      expect(await base.catalogue(), isEmpty);
      expect(await base.preview(KnowledgeLocation(imported.item.id)), isNull);
      expect(await vault.storageUsage(), const StorageUsage.zero());
    },
  );

  test(
    're-indexing makes old evidence ineligible and replaces without duplicates',
    () async {
      final item = await text('The fictional return deadline is seven days.');
      final first = await base.retrieve(
        itemId: item.id,
        question: 'return deadline',
      );
      await base.invalidateIndex(item.id);
      expect(
        (await base.catalogue()).single.item.processingState,
        KnowledgeProcessingState.needsReindexing,
      );
      expect(
        await base.retrieve(itemId: item.id, question: 'deadline'),
        isEmpty,
      );
      await base.process(item.id);
      final second = await base.retrieve(
        itemId: item.id,
        question: 'return deadline',
      );
      expect(second, hasLength(first.length));
      expect(second.single.id, isNot(first.single.id));
      await expectLater(base.cancelImport(item.id), throwsStateError);
      expect(await base.catalogue(), hasLength(1));
    },
  );

  test(
    'deletion clears original/derived content but preserves chat citation text',
    () async {
      final item = await text('The fictional return deadline is seven days.');
      final evidence = (await base.retrieve(
        itemId: item.id,
        question: 'deadline',
      )).single;
      final chat = await vault.chats.createChat();
      final turn = await vault.chats.appendTurn(
        chatId: chat.id,
        userText: 'When?',
        assistantText: 'Seven days.',
        outcome: TurnOutcome.completed,
        mode: ChatMode.knowledgeBase,
        sourceScopeIds: [item.id],
        evidencePassageIds: [evidence.id],
        citationEvidenceIndexes: [0],
        model: const ModelSnapshot(identifier: 'fake', revision: '1'),
      );
      expect(
        await base.resolveCitation(turn.provenance.evidence.single),
        isNotNull,
      );
      await base.delete(item.id);
      expect(
        await base.resolveCitation(turn.provenance.evidence.single),
        isNull,
      );
      final retained = (await vault.chats.listTurns(chat.id)).single;
      expect(retained.assistantText, 'Seven days.');
      expect(retained.provenance.evidence.single.sourceDeleted, isTrue);
      expect(
        retained.provenance.evidence.single.passageText,
        contains('seven days'),
      );
      expect((await vault.storageUsage()).knowledgeSourceBytes, 0);
      expect((await vault.storageUsage()).knowledgeIndexBytes, 0);
      expect(
        await base.retrieve(itemId: item.id, question: 'deadline'),
        isEmpty,
      );
    },
  );

  test('deletion during native query cannot return stale evidence', () async {
    final item = await text('The fictional return deadline is seven days.');
    embedder.gate = Completer<void>();
    final result = base.retrieve(itemId: item.id, question: 'deadline');
    await Future<void>.delayed(Duration.zero);
    await base.delete(item.id);
    embedder.gate!.complete();
    expect(await result, isEmpty);
  });

  test('invalid embeddings fail without publishing a partial index', () async {
    embedder.invalid = true;
    final imported = await base.importText(
      title: 'Invalid',
      text: 'The fictional return deadline is seven days.',
    );
    expect(
      (await base.process(imported.item.id)).processingState,
      KnowledgeProcessingState.failed,
    );
    expect(
      await vault.knowledge.listIndexedEvidence(imported.item.id),
      isEmpty,
    );
    embedder.invalid = false;
    expect(
      (await base.process(imported.item.id)).processingState,
      KnowledgeProcessingState.indexed,
    );
  });

  test('process-death recovery reuses durable pages after reopening', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sekret-knowledge-',
    );
    temporaryDirectories.add(directory);
    final path = '${directory.path}/vault.sqlite3';
    await base.dispose();
    await vault.close();
    vault = await openLocalDataVault(databasePath: path);
    final item = await vault.knowledge.beginProcessing(
      title: 'Recover',
      sourceType: KnowledgeSourceType.pdf,
      sourceBytes: Uint8List.fromList([1]),
      fingerprint: 'fixture-recovery',
    );
    await vault.knowledge.savePage(
      item.id,
      const KnowledgePage(
        number: 1,
        text: 'The retained fictional first page says seven days.',
      ),
      2,
    );
    await vault.close();
    vault = await openLocalDataVault(databasePath: path);
    pdf.pages = [
      'Must not be extracted again.',
      'The fictional second page says ten days.',
    ];
    base = await open();
    expect(
      (await base.catalogue()).single.item.processingState,
      KnowledgeProcessingState.paused,
    );
    await base.resume();
    expect(pdf.loaded, [2]);
    expect(
      (await base.preview(KnowledgeLocation(item.id)))!.source.pages.first.text,
      contains('retained'),
    );
  });

  test(
    'schema 3 migration retains original content and permits indexing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-knowledge-migration-',
      );
      temporaryDirectories.add(directory);
      final path = '${directory.path}/vault.sqlite3';
      final oldVault = await openLocalDataVault(databasePath: path);
      final item = await oldVault.knowledge.beginProcessing(
        title: 'Keep',
        sourceType: KnowledgeSourceType.pastedText,
        sourceBytes: Uint8List.fromList(
          'The fictional deadline is seven days.'.codeUnits,
        ),
        fingerprint: 'old',
      );
      await oldVault.close();
      final db = sqlite3.open(path);
      db.execute(
        'DROP TABLE knowledge_pages; ALTER TABLE knowledge_items DROP COLUMN processing_message; '
        'ALTER TABLE turn_provenance DROP COLUMN evidence_captured; PRAGMA user_version = 3;',
      );
      db.close();
      await base.dispose();
      await vault.close();
      vault = await openLocalDataVault(databasePath: path);
      base = await open();
      expect((await base.catalogue()).single.item.id, item.id);
      await base.resume();
      expect(
        (await base.catalogue()).single.item.processingState,
        KnowledgeProcessingState.indexed,
      );
    },
  );
}

final class GatedTokens implements TokenCounter {
  final gate = Completer<void>();
  final entered = Completer<void>();
  int calls = 0;
  @override
  Future<int> countTokens(String text) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    return text.split(RegExp(r'\s+')).length;
  }
}

final class TestEmbedder implements Embedder {
  int calls = 0;
  bool invalid = false;
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<List<double>> embed(String text) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return invalid ? [double.nan] : [1, 0.5];
  }
}

final class TestPdfLoader implements PdfTextDocumentLoader {
  List<String> pages = ['The fictional return deadline is seven days.'];
  final loaded = <int>[];
  int opens = 0;
  int disposals = 0;
  bool failOpen = false;
  int? gatedPage;
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<PdfTextDocument> open({
    required Uint8List bytes,
    required String sourceName,
  }) async {
    if (failOpen) {
      throw const PdfExtractionException(
        PdfExtractionFailureCode.passwordProtected,
        'PRIVATE',
      );
    }
    opens++;
    return TestPdfDocument(this);
  }
}

final class TestPdfDocument implements PdfTextDocument {
  TestPdfDocument(this.owner);
  final TestPdfLoader owner;
  @override
  int get pageCount => owner.pages.length;
  @override
  Future<String> loadPageText(int pageNumber) async {
    owner.loaded.add(pageNumber);
    if (pageNumber == owner.gatedPage) {
      if (!owner.entered.isCompleted) owner.entered.complete();
      await owner.gate?.future;
    }
    return owner.pages[pageNumber - 1];
  }

  @override
  Future<void> dispose() async {
    owner.disposals++;
  }
}

final class TestRasterizer implements PdfPageRasterizer {
  final requested = <int>[];
  @override
  Future<List<RasterizedPdfPage>> rasterize({
    required Uint8List bytes,
    required String sourceName,
    required List<int> pageNumbers,
    required bool Function() isCancelled,
  }) async {
    requested.addAll(pageNumbers);
    return [
      for (final number in pageNumbers)
        RasterizedPdfPage(
          pageNumber: number,
          image: OcrImageInput.encoded(Uint8List.fromList([number])),
        ),
    ];
  }
}

final class TestOcr implements OcrEngine {
  int calls = 0;
  bool fail = false;
  String text = 'The recognized fictional deadline is fourteen days.';
  @override
  Future<OcrRecognition> recognize({
    required OcrImageInput image,
    required bool Function() isCancelled,
  }) async {
    calls++;
    if (fail) {
      throw const OcrException(OcrFailureCode.recognitionFailed, 'PRIVATE');
    }
    return OcrRecognition(text: text, confidence: 0.4);
  }
}
