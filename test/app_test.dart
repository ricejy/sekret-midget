import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/app.dart';
import 'package:sekret_midget/core/library/document_library.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
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

      expect(find.text('No documents yet'), findsOneWidget);
      expect(find.byKey(const Key('question-field')), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Import pasted text'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('import-title')),
        _policyTitle,
      );
      await tester.enterText(find.byKey(const Key('import-text')), _policyText);
      await tester.tap(find.widgetWithText(FilledButton, 'Import document'));
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

  testWidgets('the import workspace lays out at iPhone width', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.reset);
    final library = await _openTestLibrary();
    addTearDown(library.close);
    await tester.pumpWidget(SekretMidgetApp(documentLibrary: library));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Import pasted text'));
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
    await tester.tap(find.widgetWithText(FilledButton, 'Import pasted text'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('import-title')),
      'Fictional failing policy',
    );
    await tester.enterText(find.byKey(const Key('import-text')), _policyText);
    await tester.tap(find.widgetWithText(FilledButton, 'Import document'));
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

Future<DocumentLibrary> _openTestLibrary() {
  return openDocumentLibrary(
    databasePath: ':memory:',
    embedder: const FakeEmbedder(),
    llmBackend: const FakeLlmBackend(),
    tokenCounter: const FakeTokenCounter(),
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
  final _answer = Completer<GeneratedAnswer>();

  void complete(String answer) => _answer.complete(
    GeneratedAnswer(text: answer, supportingEvidenceIndex: 0),
  );

  @override
  Future<LlmAvailability> availability() async => const Available();

  @override
  Future<GeneratedAnswer> generate({
    required String question,
    required List<String> evidence,
  }) {
    return _answer.future;
  }
}

final class _ThrowingEmbedder implements Embedder {
  const _ThrowingEmbedder();

  @override
  Future<List<double>> embed(String text) {
    throw StateError('synthetic embedding failure');
  }
}
