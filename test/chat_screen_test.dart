import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_engine.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/knowledge/knowledge_base.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/core/platform/token_counter.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sekret_midget/ui/chat/answer_content.dart';
import 'package:sekret_midget/ui/chat/chat_screen.dart';
import 'package:sekret_midget/ui/knowledge/source_preview.dart';

void main() => registerChatScreenTests();

void registerChatScreenTests({bool physicalDevice = false}) {
  final screenKey = GlobalKey();
  late LocalDataVault vault;
  late ChatWorkspace workspace;
  late KnowledgeBase knowledge;
  late ChatEngine engine;
  late UiModel model;
  final previews = <KnowledgePreview>[];
  final links = <Uri>[];
  var knowledgeNavigations = 0;
  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('WRITE_CHAT_SCREENSHOTS')) return;
    await tester.runAsync(() async {
      final boundary =
          screenKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/private/tmp/sekret-chat-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    // StreamIterator.cancel may return Dart's cached root-zone null Future.
    // Let real microtasks complete, then render the resulting persisted state.
    for (var i = 0; i < 3; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
  }

  Future<void> initialize(WidgetTester tester) async {
    if (const bool.fromEnvironment('WRITE_CHAT_SCREENSHOTS') &&
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
    vault = await openLocalDataVault(databasePath: ':memory:');
    workspace = await ChatWorkspace.open(vault);
    knowledge = await KnowledgeBase.open(
      vault: vault,
      embedder: const FakeEmbedder(),
      tokenCounter: const FakeTokenCounter(),
    );
    model = UiModel();
    engine = ChatEngine(
      workspace: workspace,
      backend: model,
      contextProbe: model,
      groundedBackend: model,
      knowledgeBase: knowledge,
      model: const ModelSnapshot(identifier: 'fake', revision: '1'),
    );
    previews.clear();
    links.clear();
    knowledgeNavigations = 0;
  }

  void runTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      // Serial workspace futures must live in the same fake-async zone as UI.
      await initialize(tester);
      try {
        await body(tester);
      } finally {
        final stopping = engine.stop();
        await settle(tester);
        await stopping;
        await tester.pumpWidget(const SizedBox.shrink());
        await engine.dispose();
        await knowledge.dispose();
        await workspace.dispose();
        await vault.close();
      }
    });
  }

  Future<void> mount(WidgetTester tester, {double scale = 1}) async {
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
          home: ChatScreen(
            workspace: workspace,
            engine: engine,
            knowledge: knowledge,
            onKnowledgeBase: () => knowledgeNavigations++,
            onPreview: (preview) async => previews.add(preview),
            onLink: (uri) async => links.add(uri),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder message() => find.byWidgetPredicate(
    (w) => w is CupertinoTextField && w.placeholder == 'Message',
  );
  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(message(), text);
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Send'));
    await settle(tester);
  }

  Future<TurnRecord> append(
    String chatId,
    String answer, {
    TurnOutcome outcome = TurnOutcome.completed,
    TurnFailure? failure,
  }) async {
    final turn = await vault.chats.appendTurn(
      chatId: chatId,
      userText: 'Saved question',
      assistantText: answer,
      outcome: outcome == TurnOutcome.failed ? TurnOutcome.generating : outcome,
      mode: ChatMode.general,
      sourceScopeIds: [],
      evidencePassageIds: [],
      citationEvidenceIndexes: [],
      model: const ModelSnapshot(identifier: 'fake', revision: '1'),
    );
    if (failure != null) {
      await workspace.saveResponse(
        turn.id,
        answer,
        outcome: outcome,
        failure: failure,
      );
    }
    return turn;
  }

  runTest(
    'empty state, General send, drafts and searchable persistent history',
    (tester) async {
      await mount(tester);
      expect(find.text('A little space to think.'), findsOneWidget);
      await tester.tap(find.text('Add to Knowledge Base'));
      expect(knowledgeNavigations, 1);
      await send(tester, 'Plan a fictional picnic');
      expect(find.text('General answer'), findsOneWidget);
      expect(find.text('General response.'), findsOneWidget);
      await capture(tester, 'general');
      final first = workspace.currentChatId!;
      await tester.enterText(message(), 'Draft stays here');
      await tester.tap(find.bySemanticsLabel('New Chat'));
      await settle(tester);
      expect(workspace.currentChatId, isNot(first));
      expect(find.text('Draft stays here'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Chat history'));
      await settle(tester);
      await tester.enterText(find.byType(CupertinoSearchTextField), 'picnic');
      await settle(tester);
      await tester.tap(find.text('Plan a fictional picnic'));
      await settle(tester);
      expect(workspace.currentChatId, first);
      expect(find.text('Draft stays here'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Chat history'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Rename chat').last);
      await settle(tester);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is CupertinoTextField && w.placeholder == 'Chat title',
        ),
        'Weekend plan',
      );
      await tester.tap(find.text('Save'));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        (await workspace.history()).any((c) => c.title == 'Weekend plan'),
        isTrue,
      );
    },
  );

  runTest('history swipe deletion offers Undo and preserves opened chat', (
    tester,
  ) async {
    final chat = await workspace.newChat();
    await append(chat.id, 'Retained answer');
    await mount(tester);
    await tester.tap(find.bySemanticsLabel('Chat history'));
    await settle(tester);
    await tester.drag(find.byType(Dismissible).first, const Offset(-500, 0));
    await settle(tester);
    expect(find.text('Chat deleted'), findsOneWidget);
    expect(await workspace.history(), isEmpty);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect((await workspace.history()).single.id, chat.id);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(
      (await workspace.transcript(chat.id)).single.assistantText,
      'Retained answer',
    );
  });

  runTest(
    'processing selection blocks asking, then grounded sources open captured location',
    (tester) async {
      final source = await vault.knowledge.beginProcessing(
        title: 'Return policy',
        sourceType: KnowledgeSourceType.pastedText,
        sourceBytes: Uint8List.fromList(
          utf8.encode('Return equipment within 7 days.'),
        ),
        fingerprint: 'fixture',
      );
      await mount(tester);
      await tester.tap(find.text('Knowledge Base'));
      await settle(tester);
      await tester.tap(find.text('Select sources'));
      await settle(tester);
      await tester.tap(find.text('Return policy'));
      await tester.tap(find.text('Done'));
      await settle(tester);
      await tester.enterText(message(), 'When must I return equipment?');
      final sendButton = find
          .ancestor(
            of: find.bySemanticsLabel('Send'),
            matching: find.byType(CupertinoButton),
          )
          .first;
      expect(tester.widget<CupertinoButton>(sendButton).onPressed, isNull);
      await tester.runAsync(() => knowledge.process(source.id));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Send'));
      await settle(tester);
      expect(find.text('Based on selected sources'), findsOneWidget);
      await tester.tap(find.text('Show sources (1)'));
      await settle(tester);
      await tester.ensureVisible(find.text('Open source'));
      await tester.tap(find.text('Open source'));
      await settle(tester);
      expect(previews.single.location.itemId, source.id);
      expect(previews.single.location.text, contains('7 days'));
      await capture(tester, 'grounded');
      await knowledge.delete(source.id);
      await settle(tester);
      expect(find.text('Source deleted'), findsWidgets);
      expect(find.text('Open source'), findsNothing);
      expect(
        (await workspace.transcript(
          workspace.currentChatId!,
        )).single.assistantText,
        contains('7 days'),
      );
    },
  );

  runTest('streaming Stop preserves partial text and is global across chats', (
    tester,
  ) async {
    model.stream = StreamController<String>();
    await mount(tester);
    await send(tester, 'Start a response');
    model.stream!.add('Partial response');
    await settle(tester);
    expect(find.text('Partial response'), findsOneWidget);
    expect(find.text('Responding…'), findsOneWidget);
    final first = workspace.currentChatId!;
    await tester.tap(find.bySemanticsLabel('New Chat'));
    await settle(tester);
    expect(find.bySemanticsLabel('Stop'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Stop'));
    await settle(tester);
    final stopped = (await workspace.transcript(first)).single;
    expect(stopped.outcome, TurnOutcome.stopped);
    expect(stopped.assistantText, 'Partial response');
    await workspace.openChat(first);
    await settle(tester);
    expect(find.text('Stopped · Response incomplete'), findsOneWidget);
    await tester.runAsync(model.stream!.close);
  });

  runTest('unavailable model leaves history usable and Retry recovers', (
    tester,
  ) async {
    model.status = const AppleIntelligenceNotEnabled();
    final chat = await workspace.newChat();
    await append(chat.id, 'Saved while offline');
    await mount(tester);
    expect(find.text('Enable Apple Intelligence to answer.'), findsOneWidget);
    expect(tester.widget<CupertinoTextField>(message()).enabled, isFalse);
    expect(find.text('Saved while offline'), findsOneWidget);
    model.status = const Available();
    await tester.tap(find.text('Retry'));
    await settle(tester);
    await send(tester, 'Now ready');
    expect((await workspace.transcript(chat.id)).length, 2);
  });

  runTest('turn actions copy, regenerate and confirm delete from here', (
    tester,
  ) async {
    await mount(tester);
    await send(tester, 'First message');
    await send(tester, 'Later message');
    final id = workspace.currentChatId!;
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.bySemanticsLabel('Turn actions').last);
    await settle(tester);
    await tester.tap(find.text('Copy answer'));
    await settle(tester);
    expect(copied, 'General response.');
    await tester.tap(find.bySemanticsLabel('Turn actions').last);
    await settle(tester);
    await tester.tap(find.text('Regenerate'));
    await settle(tester);
    expect((await workspace.transcript(id)).length, 3);
    await tester.tap(find.bySemanticsLabel('Turn actions').last);
    await settle(tester);
    await tester.tap(find.text('Delete from here'));
    await settle(tester);
    expect(find.text('Delete from here?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect((await workspace.transcript(id)).length, 2);
  });

  runTest(
    'summary disclosure, interrupted and typed failure states remain readable',
    (tester) async {
      final chat = await workspace.newChat();
      await append(chat.id, 'Partial', outcome: TurnOutcome.interrupted);
      await append(
        chat.id,
        '',
        outcome: TurnOutcome.failed,
        failure: TurnFailure.contextOverflow,
      );
      await mount(tester);
      expect(
        find.text('Interrupted · Regenerate to try again'),
        findsOneWidget,
      );
      expect(find.textContaining('exceeds the model context'), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await send(tester, 'Message $i');
      }
      expect(find.text('Earlier conversation summarized'), findsOneWidget);
      expect((await workspace.transcript(chat.id)).length, 7);
    },
  );

  runTest(
    'Markdown is selectable, scrollable, non-fetching and links require confirmation',
    (tester) async {
      model.answer =
          '# Heading\n\n**Bold** and *emphasis*.\n\n- One\n- Two\n\n| Name | Value |\n| --- | --- |\n| Aster | 7 |\n\n```dart\nprint(7);\n```\n\n[Website](https://example.com) ![Remote](https://example.com/track.png) [Unsafe](javascript:alert(1))';
      await mount(tester);
      await send(tester, 'Render formatting');
      expect(find.byType(AnswerContent), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Copy code'), findsOneWidget);
      expect(find.text('Heading'), findsOneWidget);
      await tester.ensureVisible(find.text('Website'));
      await tester.tap(find.text('Website'));
      await settle(tester);
      expect(links, isEmpty);
      expect(find.text('Open external link?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(links, isEmpty);
      await tester.tap(find.text('Website'));
      await settle(tester);
      await tester.tap(find.text('Open link'));
      await settle(tester);
      expect(links.single.host, 'example.com');
      expect(tester.takeException(), isNull);
    },
  );

  runTest(
    'large type and keyboard keep the composer reachable without overflow',
    (tester) async {
      await mount(tester, scale: 2);
      if (!physicalDevice) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
      }
      await settle(tester);
      await tester.enterText(message(), 'A short question');
      await settle(tester);
      expect(
        tester.getBottomRight(find.bySemanticsLabel('Send')).dy,
        lessThanOrEqualTo(
          (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
              tester.view.devicePixelRatio,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  runTest(
    'text citation preview shows the requested captured passage and original',
    (tester) async {
      final imported = await knowledge.importText(
        title: 'Aster note',
        text: 'Original evidence text.',
      );
      await tester.runAsync(() => knowledge.process(imported.item.id));
      final preview = await knowledge.preview(
        KnowledgeLocation(imported.item.id, text: 'evidence text'),
      );
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
          home: SourcePreview(
            knowledge: knowledge,
            location: preview!.location,
          ),
        ),
      );
      await settle(tester);
      expect(find.text('Captured passage'), findsOneWidget);
      expect(find.text('Original evidence text.'), findsOneWidget);
    },
  );
  runTest(
    'dark mode and insufficient evidence keep mode labels and exact answer',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final imported = await knowledge.importText(
        title: 'Aster note',
        text: 'Return equipment within 7 days.',
      );
      await tester.runAsync(() => knowledge.process(imported.item.id));
      final chat = await workspace.newChat();
      await workspace.changeScope(chat.id, ChatMode.knowledgeBase, [
        imported.item.id,
      ]);
      model.groundedAnswer =
          'I couldn’t find enough evidence in this document.';
      await mount(tester);
      await send(tester, 'What is the missing fee?');
      expect(
        find.text('I couldn’t find enough evidence in this document.'),
        findsOneWidget,
      );
      expect(find.text('General answer'), findsNothing);
      await capture(tester, 'dark');
      expect(tester.takeException(), isNull);
    },
  );
}

class UiModel
    implements GeneralLlmBackend, GroundedLlmBackend, ModelContextProbe {
  LlmAvailability status = const Available();
  String answer = 'General response.';
  String? groundedAnswer;
  StreamController<String>? stream;
  @override
  Future<LlmAvailability> availability() async => status;
  @override
  Stream<String> generateGeneral({required String prompt}) async* {
    if (stream case final controller?) {
      yield* controller.stream;
    } else {
      yield answer;
    }
  }

  @override
  Stream<String> generateGrounded({required String prompt}) async* {
    final evidence = (jsonDecode(prompt) as Map)['current_evidence'] as List;
    yield groundedAnswer ?? evidence.map((e) => e['passage']).join('\n');
  }

  @override
  Future<int> contextWindowSize() async => 10000;
  @override
  Future<int> countInstructionTokens(String text) async => 100;
  @override
  Future<int> countPromptTokens(String text) async => text.length ~/ 4 + 1;
}
