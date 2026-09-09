import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/knowledge/knowledge_base.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sekret_midget/ui/knowledge/knowledge_screen.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/pdf_file_picker.dart';
import 'package:sekret_midget/core/platform/document_image_picker.dart';
import 'package:sekret_midget/core/platform/pdf_text_extractor.dart';
import 'package:sekret_midget/core/platform/pdfrx_pdf_text_extractor.dart';
import 'package:sekret_midget/core/platform/pdfrx_pdf_page_rasterizer.dart';
import 'package:sekret_midget/core/platform/pdf_page_rasterizer.dart';
import 'package:sekret_midget/core/platform/ocr_engine.dart';
import 'package:pdfrx/pdfrx.dart';
import 'fixtures/preview_fixtures.dart';

void main() => registerKnowledgeScreenTests();

void registerKnowledgeScreenTests({bool physicalDevice = false}) {
  final screenKey = GlobalKey();
  late LocalDataVault vault;
  late KnowledgeBase knowledge;
  late UiKnowledgeEmbedder embedder;
  late UiKnowledgePicker picker;
  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('WRITE_KNOWLEDGE_SCREENSHOTS')) return;
    await tester.runAsync(() async {
      final boundary =
          screenKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/private/tmp/sekret-knowledge-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    for (var i = 0; i < 3; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      vault = await openLocalDataVault(databasePath: ':memory:');
      embedder = UiKnowledgeEmbedder();
      picker = UiKnowledgePicker();
      knowledge = await KnowledgeBase.open(
        vault: vault,
        embedder: embedder,
        tokenCounter: const FakeTokenCounter(),
        pdfLoader: physicalDevice
            ? const PdfrxDocumentLoader()
            : UiKnowledgePdfLoader(),
        rasterizer: physicalDevice
            ? const PdfrxPdfPageRasterizer()
            : UiKnowledgeRasterizer(),
        ocr: UiKnowledgeOcr(),
      );
      try {
        await body(tester);
      } finally {
        if (embedder.gate != null && !embedder.gate!.isCompleted) {
          embedder.gate!.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(knowledge.dispose);
        await vault.close();
      }
    });
  }

  Future<void> mount(WidgetTester tester, {double scale = 1}) async {
    if (const bool.fromEnvironment('WRITE_KNOWLEDGE_SCREENSHOTS') &&
        Platform.isMacOS) {
      await tester.runAsync(() async {
        for (final family in [
          'CupertinoSystemText',
          'CupertinoSystemDisplay',
        ]) {
          await (FontLoader(family)..addFont(
                File(
                  '/System/Library/Fonts/SFNS.ttf',
                ).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
              rootBundle.load(
                'packages/cupertino_icons/assets/CupertinoIcons.ttf',
              ),
            ))
            .load();
      });
    }
    if (!physicalDevice) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenKey,
        child: CupertinoApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: KnowledgeScreen(
            knowledge: knowledge,
            pdfPicker: picker,
            imagePicker: picker,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  scenario('catalogue searches extracted text and filters source types', (
    tester,
  ) async {
    final imported = await knowledge.importText(
      title: 'Travel policy',
      text: 'Return the fictional camera equipment within seven days.',
    );
    await tester.runAsync(() => knowledge.process(imported.item.id));
    await mount(tester);
    expect(find.text('Travel policy'), findsOneWidget);
    expect(find.textContaining('Indexed'), findsOneWidget);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'camera');
    await settle(tester);
    expect(find.textContaining('seven days'), findsOneWidget);
    await tester.tap(find.text('All types'));
    await settle(tester);
    await tester.tap(find.text('PDF'));
    await settle(tester);
    expect(find.text('No matching items'), findsOneWidget);
  });

  scenario(
    'pasted text imports once and duplicates offer the existing source',
    (tester) async {
      await mount(tester);
      Future<void> paste() async {
        await tester.tap(find.bySemanticsLabel('Add knowledge'));
        await settle(tester);
        await tester.tap(find.text('Paste text'));
        await settle(tester);
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is CupertinoTextField && w.placeholder == 'Title',
          ),
          'Equipment policy',
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (w) =>
                w is CupertinoTextField && w.placeholder == 'Paste your text',
          ),
          'Return equipment within seven days.',
        );
        await settle(tester);
        await tester.tap(find.text('Import'));
        await settle(tester);
      }

      await paste();
      expect(find.text('Equipment policy'), findsOneWidget);
      await paste();
      expect(find.text('Already in your Knowledge Base'), findsOneWidget);
      await tester.tap(find.text('Keep existing'));
      await settle(tester);
      expect(find.text('Equipment policy'), findsOneWidget);
    },
  );

  scenario('rename and permanent deletion warn that related chats remain', (
    tester,
  ) async {
    final imported = await knowledge.importText(
      title: 'Old title',
      text: 'Return equipment within seven days.',
    );
    await tester.runAsync(() => knowledge.process(imported.item.id));
    await mount(tester);
    await tester.tap(find.bySemanticsLabel('Actions for Old title'));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is CupertinoTextField && w.placeholder == 'Title',
      ),
      'New title',
    );
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('New title'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Actions for New title'));
    await settle(tester);
    await tester.tap(find.text('Delete source'));
    await settle(tester);
    expect(find.textContaining('Chat text remains'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text('New title'), findsOneWidget);
    await tester.drag(find.text('New title'), const Offset(-320, 0));
    await settle(tester);
    await tester.tap(find.text('Delete permanently'));
    await settle(tester);
    expect(find.text('New title'), findsNothing);
    expect(
      await knowledge.preview(KnowledgeLocation(imported.item.id)),
      isNull,
    );
  });

  scenario(
    'preview searches selectable original text and invalidates deleted sources',
    (tester) async {
      final imported = await knowledge.importText(
        title: 'Equipment note',
        text: 'Return equipment within seven days. Keep equipment dry.',
      );
      await tester.runAsync(() => knowledge.process(imported.item.id));
      await mount(tester);
      await tester.tap(find.text('Equipment note'));
      await settle(tester);
      expect(
        find.text('Return equipment within seven days. Keep equipment dry.'),
        findsOneWidget,
      );
      final original = find.byWidgetPredicate(
        (w) => w is EditableText && w.readOnly,
      );
      await tester.longPressAt(
        tester.getTopLeft(original) + const Offset(30, 12),
      );
      await settle(tester);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await settle(tester);
      await tester.enterText(
        find.byType(CupertinoSearchTextField),
        'equipment',
      );
      await settle(tester);
      expect(find.text('1 of 2 matches'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Next match'));
      await settle(tester);
      expect(find.text('2 of 2 matches'), findsOneWidget);
      await knowledge.delete(imported.item.id);
      await settle(tester);
      expect(find.text('Source deleted'), findsOneWidget);
      expect(find.textContaining('Keep equipment dry'), findsNothing);
    },
  );

  scenario('failed indexing can retry and be cancelled while processing', (
    tester,
  ) async {
    embedder.fail = true;
    final imported = await knowledge.importText(
      title: 'Retry policy',
      text: 'Return equipment within seven days.',
    );
    await tester.runAsync(() => knowledge.process(imported.item.id));
    await mount(tester);
    expect(find.textContaining('Failed'), findsOneWidget);
    embedder.fail = false;
    embedder.gate = Completer<void>();
    await tester.tap(find.bySemanticsLabel('Actions for Retry policy'));
    await settle(tester);
    await tester.tap(find.text('Retry indexing'));
    await settle(tester);
    expect(find.textContaining('Processing'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Actions for Retry policy'));
    await settle(tester);
    await tester.tap(find.text('Cancel import'));
    await settle(tester);
    await tester.tap(find.text('Discard import'));
    await settle(tester);
    embedder.gate!.complete();
    await settle(tester);
    expect(find.text('Retry policy'), findsNothing);
  });

  scenario(
    '500-item catalogue remains searchable with large text and state filters',
    (tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 500; i++) {
          final item = await knowledge.importText(
            title: 'Policy $i',
            text: 'Equipment rule $i. Return it within seven days.',
          );
          await knowledge.process(item.item.id);
        }
      });
      await mount(tester, scale: 2);
      expect(find.text('500 items'), findsOneWidget);
      await tester.tap(find.text('All states'));
      await settle(tester);
      await tester.tap(
        find.widgetWithText(CupertinoActionSheetAction, 'Indexed'),
      );
      await settle(tester);
      await tester.enterText(
        find.byType(CupertinoSearchTextField),
        'rule 499.',
      );
      await settle(tester);
      expect(find.text('Policy 499'), findsOneWidget);
      expect(find.text('1 item'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    're-index warning, pause and needs-reindexing recover without replacing the original',
    (tester) async {
      final imported = await knowledge.importText(
        title: 'Saved policy',
        text: 'Keep equipment dry.',
      );
      await tester.runAsync(() => knowledge.process(imported.item.id));
      await mount(tester);
      embedder.gate = Completer<void>();
      await tester.tap(find.bySemanticsLabel('Actions for Saved policy'));
      await settle(tester);
      await tester.tap(find.text('Re-index'));
      await settle(tester);
      expect(find.textContaining('cannot support new answers'), findsOneWidget);
      await tester.tap(find.text('Re-index'));
      await settle(tester);
      final suspended = knowledge.suspend();
      embedder.gate!.complete();
      await settle(tester);
      await suspended;
      expect(find.textContaining('Paused'), findsOneWidget);
      final resuming = knowledge.resume();
      await settle(tester);
      await resuming;
      expect(find.text('Indexed'), findsOneWidget);
      await knowledge.invalidateIndex(imported.item.id);
      await settle(tester);
      expect(find.textContaining('Needs re-indexing'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Actions for Saved policy'));
      await settle(tester);
      await tester.tap(find.text('Retry indexing'));
      await settle(tester);
      expect(find.text('Indexed'), findsOneWidget);
      await tester.tap(find.text('Saved policy'));
      await settle(tester);
      expect(find.text('Keep equipment dry.'), findsOneWidget);
    },
  );

  scenario(
    'an action on a just-deleted source reports failure instead of silently disappearing',
    (tester) async {
      final imported = await knowledge.importText(
        title: 'Removed elsewhere',
        text: 'Keep equipment dry.',
      );
      await tester.runAsync(() => knowledge.process(imported.item.id));
      await mount(tester);
      await tester.tap(find.bySemanticsLabel('Actions for Removed elsewhere'));
      await settle(tester);
      await tester.tap(find.text('Rename'));
      await settle(tester);
      await knowledge.delete(imported.item.id);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(
        find.text('The action could not finish. Refresh and try again.'),
        findsOneWidget,
      );
    },
  );

  scenario('dark mode and large type keep catalogue and source search usable', (
    tester,
  ) async {
    final fixtures = (await tester.runAsync(previewFixtures))!;
    final note = await knowledge.importText(
      title: 'Field notes',
      text: 'Return the equipment within seven days. Keep equipment dry.',
    );
    await tester.runAsync(() => knowledge.process(note.item.id));
    final pdf = await knowledge.importSource(
      title: 'Travel agreement',
      sourceName: 'Travel agreement.pdf',
      sourceType: KnowledgeSourceType.pdf,
      bytes: fixtures.pdf,
    );
    await tester.runAsync(() => knowledge.process(pdf.item.id));
    final photo = await knowledge.importSource(
      title: 'Equipment receipt',
      sourceName: 'Receipt.png',
      sourceType: KnowledgeSourceType.photo,
      bytes: fixtures.photo,
    );
    await tester.runAsync(() => knowledge.process(photo.item.id));
    await knowledge.invalidateIndex(photo.item.id);
    await mount(tester);
    await capture(tester, 'catalogue');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await settle(tester);
    await capture(tester, 'dark');
    await mount(tester, scale: 2);
    await tester.enterText(
      find.byType(CupertinoSearchTextField),
      'Field notes',
    );
    await settle(tester);
    await tester.tap(
      find.byWidgetPredicate((w) => w is Text && w.data == 'Field notes'),
    );
    await settle(tester);
    await tester.enterText(find.byType(CupertinoSearchTextField), 'equipment');
    await settle(tester);
    expect(find.text('1 of 2 matches'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'large-preview');
  });

  Future<void> pinch(WidgetTester tester, Finder target) async {
    final center = tester.getCenter(target);
    final first = await tester.startGesture(
      center - const Offset(25, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(25, 0),
      pointer: 2,
    );
    for (var i = 1; i <= 5; i++) {
      await first.moveTo(center - Offset(25 + i * 12, 0));
      await second.moveTo(center + Offset(25 + i * 12, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await first.up();
    await second.up();
    await settle(tester);
  }

  for (final kind in ['PDF', 'Scan', 'Photo']) {
    scenario(
      '$kind imports, opens its original and exposes searchable extracted text',
      (tester) async {
        final fixtures = (await tester.runAsync(previewFixtures))!;
        picker.bytes = kind == 'Photo'
            ? fixtures.photo
            : kind == 'Scan'
            ? fixtures.scan
            : fixtures.pdf;
        picker.name = '$kind.${kind == 'Photo' ? 'png' : 'pdf'}';
        await mount(tester);
        await tester.tap(find.bySemanticsLabel('Add knowledge'));
        await settle(tester);
        await tester.tap(
          find.text(kind == 'Photo' ? 'Choose photograph' : 'Choose PDF'),
        );
        await settle(tester);
        final item = (await knowledge.catalogue()).single.item;
        await tester.runAsync(() => knowledge.process(item.id));
        await settle(tester);
        expect(find.textContaining('Indexed'), findsOneWidget);
        await tester.tap(find.text(picker.name));
        await settle(tester);
        if (kind == 'Photo') {
          expect(find.byType(InteractiveViewer), findsOneWidget);
          expect(find.bySemanticsLabel('Original photograph'), findsOneWidget);
          final width = tester.getSize(find.byType(Image)).width;
          await pinch(tester, find.byType(InteractiveViewer));
          expect(tester.getRect(find.byType(Image)).width, greaterThan(width));
        } else {
          if (physicalDevice) {
            expect(find.byType(PdfViewer), findsOneWidget);
            final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
            for (var i = 0; i < 100 && !viewer.controller!.isReady; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(viewer.controller!.isReady, isTrue);
            expect(viewer.controller!.pageCount, kind == 'Scan' ? 1 : 2);
            final zoom = viewer.controller!.currentZoom;
            await pinch(tester, find.byType(PdfViewer));
            expect(viewer.controller!.currentZoom, greaterThan(zoom));
          } else {
            expect(
              find.text('PDF preview unavailable. Try Extracted text.'),
              findsOneWidget,
            );
          }
        }
        if (kind == 'PDF') {
          await tester.tap(find.bySemanticsLabel('Next page'));
          await settle(tester);
          expect(find.text('Page 2 of 2'), findsOneWidget);
          await tester.tap(find.bySemanticsLabel('Previous page'));
          await settle(tester);
        }
        await tester.tap(find.text('Extracted text'));
        await settle(tester);
        await tester.enterText(
          find.byType(CupertinoSearchTextField),
          'equipment',
        );
        await settle(tester);
        expect(find.textContaining('of 2 matches'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Next match'));
        await settle(tester);
        if (kind == 'PDF') {
          expect(find.text('Page 2 of 2'), findsOneWidget);
          expect(find.textContaining('Keep equipment dry.'), findsOneWidget);
        }
        await tester.tap(find.bySemanticsLabel('Source information'));
        await settle(tester);
        expect(
          find.textContaining('Read-only. Stored on this device.'),
          findsOneWidget,
        );
        if (kind != 'PDF') {
          expect(find.textContaining('low confidence'), findsOneWidget);
        }
        await tester.tap(find.text('Done'));
        await settle(tester);
        await knowledge.delete(item.id);
        await settle(tester);
        expect(find.text('Source deleted'), findsOneWidget);
        expect(find.byType(PdfViewer), findsNothing);
        expect(find.bySemanticsLabel('Original photograph'), findsNothing);
      },
    );
  }
}

class UiKnowledgeEmbedder implements Embedder {
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<List<double>> embed(String text) async {
    await gate?.future;
    if (fail) throw StateError('Fixture failure');
    return [1, 0];
  }
}

class UiKnowledgePicker implements PdfFilePicker, DocumentImagePicker {
  Uint8List? bytes;
  String name = '';
  @override
  Future<SelectedPdfFile?> pickPdf() async =>
      bytes == null ? null : SelectedPdfFile(name: name, bytes: bytes!);
  @override
  Future<SelectedDocumentImage?> pickImage() async =>
      bytes == null ? null : SelectedDocumentImage(name: name, bytes: bytes!);
}

class UiKnowledgePdfLoader implements PdfTextDocumentLoader {
  @override
  Future<PdfTextDocument> open({
    required Uint8List bytes,
    required String sourceName,
  }) async => UiKnowledgePdf(sourceName.startsWith('Scan'));
}

class UiKnowledgePdf implements PdfTextDocument {
  UiKnowledgePdf(this.scan);
  final bool scan;
  @override
  int get pageCount => scan ? 1 : 2;
  @override
  Future<String> loadPageText(int pageNumber) async => scan
      ? ''
      : pageNumber == 1
      ? 'Return equipment within seven days.'
      : 'Keep equipment dry.';
  @override
  Future<void> dispose() async {}
}

class UiKnowledgeOcr implements OcrEngine {
  @override
  Future<OcrRecognition> recognize({
    required OcrImageInput image,
    required bool Function() isCancelled,
  }) async => const OcrRecognition(
    text: 'Return equipment within seven days. Keep equipment dry.',
    confidence: .5,
  );
}

class UiKnowledgeRasterizer implements PdfPageRasterizer {
  @override
  Future<List<RasterizedPdfPage>> rasterize({
    required Uint8List bytes,
    required String sourceName,
    required List<int> pageNumbers,
    required bool Function() isCancelled,
  }) async => [
    for (final page in pageNumbers)
      RasterizedPdfPage(pageNumber: page, image: OcrImageInput.encoded(bytes)),
  ];
}
