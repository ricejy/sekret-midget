import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/app.dart';
import 'package:sekret_midget/core/library/document_library.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/core/platform/pdf_file_picker.dart';
import 'package:sekret_midget/core/platform/pdf_text_extractor.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';

const _policyTitle = 'Fictional Orion Safety Policy';
const _policyText = '''
INCIDENT REPORTING

Employees must report a workplace incident to the safety officer within 14 calendar days.
''';

void main() {
  testWidgets(
    'user imports pasted text, selects it, and asks a grounded question',
    (tester) async {
      _useWideTestSurface(tester);
      final library = await _openTestLibrary();
      addTearDown(library.close);

      await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
      await tester.pumpAndSettle();

      expect(
        find.text('Deterministic fake · en · 5 dimensions · revision 1'),
        findsOneWidget,
      );
      expect(find.text('No documents yet'), findsOneWidget);
      expect(find.byKey(const Key('question-field')), findsNothing);
      await tester.tap(find.byKey(const Key('open-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('import-title')),
        _policyTitle,
      );
      await tester.enterText(find.byKey(const Key('import-text')), _policyText);
      await tester.tap(find.byKey(const Key('execute-import')));
      await tester.pumpAndSettle();

      expect(find.text('Extracted'), findsOneWidget);
      expect(find.text('Chunked'), findsOneWidget);
      expect(find.text('Embedded'), findsOneWidget);
      expect(find.text('Indexed'), findsOneWidget);
      await _selectPolicy(tester);
      await tester.enterText(
        find.byKey(const Key('question-field')),
        'How soon must an employee report an incident?',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'An employee must report an incident within 14 calendar days.',
        ),
        findsOneWidget,
      );
      expect(find.text('INCIDENT REPORTING'), findsOneWidget);
    },
  );

  testWidgets(
    'user selects a fictional PDF and receives a page-aware grounded answer',
    (tester) async {
      _useWideTestSurface(tester);
      final fixtureBytes = File(
        'test/fixtures/fictional_text_contract.pdf',
      ).readAsBytesSync();
      final extractor = _FixturePdfExtractor();
      final library = await _openTestLibrary(pdfTextExtractor: extractor);
      addTearDown(library.close);

      await tester.pumpWidget(
        SekretMidgetApp(
          documentLibrary: library,
          pdfFilePicker: _FixturePdfPicker(fixtureBytes),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-import')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('choose-pdf')));
      await tester.pumpAndSettle();

      expect(find.text('fictional_text_contract.pdf'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'fictional_text_contract'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('import-text')), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Import PDF'));
      await tester.pumpAndSettle();

      expect(extractor.sourceName, 'fictional_text_contract.pdf');
      expect(extractor.receivedBytes, fixtureBytes);
      expect(_stageStatus('Extracted complete'), findsOneWidget);
      expect(_stageStatus('Chunked complete'), findsOneWidget);
      expect(_stageStatus('Embedded complete'), findsOneWidget);
      expect(_stageStatus('Indexed complete'), findsOneWidget);

      await tester.tap(find.widgetWithText(InkWell, 'fictional_text_contract'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('question-field')),
        'How much notice is required to end employment?',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Either fictional party must provide forty-five calendar days of written notice.',
        ),
        findsOneWidget,
      );
      expect(find.text('NOTICE PERIOD · Page 2'), findsOneWidget);
    },
  );

  testWidgets('cancelling PDF extraction leaves no document in the library', (
    tester,
  ) async {
    _useWideTestSurface(tester);
    final extractor = _BlockingPdfExtractor();
    final library = await _openTestLibrary(pdfTextExtractor: extractor);
    addTearDown(library.close);
    await tester.pumpWidget(
      SekretMidgetApp(
        documentLibrary: library,
        pdfFilePicker: _FixturePdfPicker(
          Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-pdf')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import PDF'));
    await tester.pump();
    await extractor.started.future;

    expect(
      find.widgetWithText(OutlinedButton, 'Cancel import'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel import'));
    extractor.finish();
    await tester.pumpAndSettle();

    expect(
      find.text('Import cancelled. No document data was saved.'),
      findsOneWidget,
    );
    expect(await library.listDocuments(), isEmpty);
  });

  testWidgets('the import workspace lays out at iPhone width', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.reset);
    final library = await _openTestLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('import-title')), findsOneWidget);
    expect(find.byKey(const Key('import-text')), findsOneWidget);
  });

  testWidgets('an answer is discarded when another document is selected', (
    tester,
  ) async {
    _useWideTestSurface(tester);
    final backend = _ControllableLlmBackend();
    final library = await openDocumentLibrary(
      databasePath: ':memory:',
      embedder: const FakeEmbedder(),
      llmBackend: backend,
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(library.close);
    await library
        .importPastedText(title: 'Document A', text: _policyText)
        .drain<void>();
    await library
        .importPastedText(
          title: 'Document B',
          text: 'EQUIPMENT\n\nProtective equipment remains company property.',
        )
        .drain<void>();
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InkWell, 'Document A'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('question-field')),
      'When must an incident be reported?',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
    await tester.pump();
    await tester.tap(find.widgetWithText(InkWell, 'Document B'));
    await tester.pump();
    backend.complete(
      'An employee must report an incident within 14 calendar days.',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('An employee must report an incident within 14 calendar days.'),
      findsNothing,
    );
    expect(find.text('Document B'), findsWidgets);
  });

  testWidgets('answer snapshots are visible before grounded completion', (
    tester,
  ) async {
    _useWideTestSurface(tester);
    final backend = _ControllableLlmBackend();
    final library = await openDocumentLibrary(
      databasePath: ':memory:',
      embedder: const FakeEmbedder(),
      llmBackend: backend,
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(library.close);
    await library
        .importPastedText(title: _policyTitle, text: _policyText)
        .drain<void>();
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();
    await _selectPolicy(tester);
    await tester.enterText(
      find.byKey(const Key('question-field')),
      'When must an incident be reported?',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
    await tester.pump();

    backend.emit('An employee must report');
    await tester.pump();

    expect(find.byKey(const Key('streaming-answer')), findsOneWidget);
    expect(find.text('An employee must report'), findsOneWidget);
    expect(find.text('GROUNDED ANSWER'), findsNothing);

    backend.complete(
      'An employee must report an incident within 14 calendar days.',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('streaming-answer')), findsNothing);
    expect(find.text('GROUNDED ANSWER'), findsOneWidget);
    expect(find.text('INCIDENT REPORTING'), findsOneWidget);
  });

  testWidgets('a persistent library startup failure is shown in the app', (
    tester,
  ) async {
    final startup = Completer<DocumentLibrary>();
    await tester.pumpWidget(
      SekretMidgetApp(documentLibraryFuture: startup.future),
    );
    startup.completeError(StateError('synthetic corrupt database detail'));
    await tester.pumpAndSettle();

    expect(
      find.text('The private document library could not be opened.'),
      findsOneWidget,
    );
    expect(find.textContaining('synthetic corrupt'), findsNothing);
  });

  testWidgets('a failed import checks only stages that actually finished', (
    tester,
  ) async {
    _useWideTestSurface(tester);
    final library = await openDocumentLibrary(
      databasePath: ':memory:',
      embedder: const _ThrowingEmbedder(),
      llmBackend: const FakeLlmBackend(),
      tokenCounter: const FakeTokenCounter(),
    );
    addTearDown(library.close);
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('import-title')),
      'Fictional failing policy',
    );
    await tester.enterText(find.byKey(const Key('import-text')), _policyText);
    await tester.tap(find.byKey(const Key('execute-import')));
    await tester.pumpAndSettle();

    expect(_stageStatus('Extracted complete'), findsOneWidget);
    expect(_stageStatus('Chunked complete'), findsOneWidget);
    expect(_stageStatus('Embedded pending'), findsOneWidget);
    expect(_stageStatus('Indexed pending'), findsOneWidget);
  });

  testWidgets(
    'an ineligible device explains that on-device answers are unavailable',
    (tester) async {
      final library = await _openLibraryWithPolicy();
      addTearDown(library.close);
      await tester.pumpWidget(
        SekretMidgetApp(
          documentLibrary: library,
          modelAvailability: const DeviceNotEligible(),
        ),
      );
      await tester.pumpAndSettle();
      await _selectPolicy(tester);

      expect(
        find.text('This device cannot run Apple Intelligence.'),
        findsOneWidget,
      );
      expect(
        find.text('On-device answers require an eligible iPhone.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Ask document'), findsNothing);
    },
  );

  testWidgets('disabled Apple Intelligence offers a Settings action', (
    tester,
  ) async {
    final library = await _openLibraryWithPolicy();
    addTearDown(library.close);
    await tester.pumpWidget(
      SekretMidgetApp(
        documentLibrary: library,
        modelAvailability: const AppleIntelligenceNotEnabled(),
      ),
    );
    await tester.pumpAndSettle();
    await _selectPolicy(tester);

    expect(find.text('Apple Intelligence is turned off.'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Open Settings'),
      findsOneWidget,
    );
  });

  testWidgets('model assets that are not ready offer a retry', (tester) async {
    final library = await _openLibraryWithPolicy();
    addTearDown(library.close);
    await tester.pumpWidget(
      SekretMidgetApp(
        documentLibrary: library,
        modelAvailability: const ModelNotReady(),
      ),
    );
    await tester.pumpAndSettle();
    await _selectPolicy(tester);

    expect(
      find.text('The on-device model is still getting ready.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Check again'), findsOneWidget);
  });

  testWidgets('user sees the fixed response when evidence is insufficient', (
    tester,
  ) async {
    final library = await _openLibraryWithPolicy();
    addTearDown(library.close);
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();
    await _selectPolicy(tester);

    await tester.enterText(
      find.byKey(const Key('question-field')),
      'Does termination happen immediately when fraud is alleged?',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
    await tester.pumpAndSettle();

    expect(
      find.text('I couldn’t find enough evidence in this document.'),
      findsOneWidget,
    );
    expect(find.text('GROUNDED ANSWER'), findsNothing);
  });

  testWidgets('user can delete a document and its library entry disappears', (
    tester,
  ) async {
    _useWideTestSurface(tester);
    final library = await _openTestLibrary();
    addTearDown(library.close);
    await library
        .importPastedText(
          title: 'Fictional policy to delete',
          text: _policyText,
        )
        .drain<void>();
    await library
        .importPastedText(title: 'Fictional policy to keep', text: _policyText)
        .drain<void>();
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete Fictional policy to delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this document?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete document'));
    await tester.pumpAndSettle();

    expect(find.text('Fictional policy to delete'), findsNothing);
    expect(find.text('Fictional policy to keep'), findsOneWidget);
  });
}

Future<DocumentLibrary> _openTestLibrary({
  PdfTextExtractor pdfTextExtractor = const UnavailablePdfTextExtractor(),
}) {
  return openDocumentLibrary(
    databasePath: ':memory:',
    embedder: const FakeEmbedder(),
    llmBackend: const FakeLlmBackend(),
    tokenCounter: const FakeTokenCounter(),
    pdfTextExtractor: pdfTextExtractor,
  );
}

Future<DocumentLibrary> _openLibraryWithPolicy() async {
  final library = await _openTestLibrary();
  await library
      .importPastedText(title: _policyTitle, text: _policyText)
      .drain<void>();
  return library;
}

Future<void> _selectPolicy(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(InkWell, _policyTitle));
  await tester.pumpAndSettle();
}

void _useWideTestSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(tester.view.reset);
}

Finder _stageStatus(String label) {
  return find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );
}

final class _ControllableLlmBackend implements LlmBackend {
  final _answer = StreamController<String>();

  void emit(String answer) => _answer.add(answer);

  void complete(String answer) {
    _answer.add(answer);
    unawaited(_answer.close());
  }

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) {
    return _answer.stream;
  }
}

final class _ThrowingEmbedder implements Embedder {
  const _ThrowingEmbedder();

  @override
  Future<List<double>> embed(String text) {
    throw StateError('synthetic embedding failure');
  }
}

final class _FixturePdfPicker implements PdfFilePicker {
  const _FixturePdfPicker(this.bytes);

  final Uint8List bytes;

  @override
  Future<SelectedPdfFile?> pickPdf() async {
    return SelectedPdfFile(name: 'fictional_text_contract.pdf', bytes: bytes);
  }
}

final class _FixturePdfExtractor implements PdfTextExtractor {
  Uint8List? receivedBytes;
  String? sourceName;

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) async {
    receivedBytes = bytes;
    this.sourceName = sourceName;
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

Either fictional party must provide forty-five calendar days of written notice before ending employment.
''',
        ),
        ExtractedPdfPage(
          pageNumber: 3,
          text: '''
COMPENSATION DATE

Compensation is paid on the final business day of each month.
''',
        ),
      ],
    );
  }
}

final class _BlockingPdfExtractor implements PdfTextExtractor {
  final started = Completer<void>();
  final _result = Completer<ExtractedPdf>();

  void finish() {
    _result.complete(
      const ExtractedPdf(
        pages: [
          ExtractedPdfPage(
            pageNumber: 1,
            text: 'NOTICE PERIOD\n\nFictional notice is forty-five days.',
          ),
        ],
      ),
    );
  }

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) {
    started.complete();
    return _result.future;
  }
}
