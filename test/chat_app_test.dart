import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_engine.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/knowledge/knowledge_base.dart';
import 'package:sekret_midget/core/platform/apple_foundation_models.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sekret_midget/ui/sekret_chat_app.dart';
import 'chat_screen_test.dart' show UiModel;

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'tabs keep generation alive, while backgrounding obscures and interrupts',
    (tester) async {
      final vault = await openLocalDataVault(databasePath: ':memory:');
      final workspace = await ChatWorkspace.open(vault);
      final knowledge = await KnowledgeBase.open(
        vault: vault,
        embedder: const FakeEmbedder(),
        tokenCounter: const FakeTokenCounter(),
      );
      final model = UiModel()..stream = StreamController<String>();
      final engine = ChatEngine(
        workspace: workspace,
        backend: model,
        contextProbe: model,
        groundedBackend: model,
        knowledgeBase: knowledge,
        model: const ModelSnapshot(identifier: 'fixture', revision: '1'),
      );
      final resources = ChatAppResources(
        vault,
        workspace,
        knowledge,
        engine,
        AppleFoundationModels(events: const Stream.empty()),
      );
      await tester.pumpWidget(
        SekretChatApp(openResources: () async => resources),
      );
      await settle(tester);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is CupertinoTextField && w.placeholder == 'Message',
        ),
        'Start a response',
      );
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Send'));
      await settle(tester);
      final chatId = workspace.currentChatId!;
      model.stream!.add('Private partial response');
      await settle(tester);
      expect(engine.isGenerating, isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('Knowledge Base'),
        ),
      );
      await settle(tester);
      expect(engine.isGenerating, isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('Chat'),
        ),
      );
      await settle(tester);
      expect(find.text('Private partial response'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(tester);
      expect(find.text('Private partial response').hitTestable(), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settle(tester);
      expect(engine.isGenerating, isFalse);
      expect(
        (await workspace.transcript(chatId)).single.outcome,
        TurnOutcome.interrupted,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(
        find.text('Interrupted · Regenerate to try again'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      await tester.runAsync(model.stream!.close);
    },
  );

  testWidgets('startup failure explains that existing data is not reset', (
    tester,
  ) async {
    await tester.pumpWidget(
      SekretChatApp(
        openResources: () async =>
            throw const UnrecognizedVaultSchemaException(['documents']),
      ),
    );
    await settle(tester);
    expect(
      find.textContaining('Existing data has not been reset.'),
      findsOneWidget,
    );
    expect(find.byType(CupertinoTabBar), findsNothing);
  });
}
