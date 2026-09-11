import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_engine.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/knowledge/knowledge_base.dart';
import 'package:sekret_midget/core/platform/apple_foundation_models.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sekret_midget/ui/sekret_chat_app.dart';
import 'app_protection_test.dart' show FakeDeviceProtection;
import 'chat_screen_test.dart' show UiModel;
import 'knowledge_screen_test.dart' show UiKnowledgeEmbedder;

Future<void> settleSettings(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  Future<ChatAppResources> resources(
    FakeDeviceProtection device, {
    bool onboarding = true,
    bool lock = false,
    DateTime Function()? clock,
    UiModel? model,
    Embedder embedder = const FakeEmbedder(),
  }) async {
    final vault = await openLocalDataVault(
      databasePath: ':memory:',
      clock: clock,
    );
    await vault.settings.update(
      retentionPolicy: RetentionPolicy.manual,
      biometricLockEnabled: lock,
      lockDelay: AppLockDelay.immediate,
      onboardingComplete: onboarding,
    );
    final workspace = await ChatWorkspace.open(vault, clock: clock);
    final knowledge = await KnowledgeBase.open(
      vault: vault,
      embedder: embedder,
      tokenCounter: const FakeTokenCounter(),
    );
    model ??= UiModel();
    return ChatAppResources(
      vault,
      workspace,
      knowledge,
      ChatEngine(
        workspace: workspace,
        backend: model,
        contextProbe: model,
        groundedBackend: model,
        knowledgeBase: knowledge,
        model: const ModelSnapshot(identifier: 'fixture', revision: '1'),
      ),
      AppleFoundationModels(
        channel: const MethodChannel('sekret/settings-fixture'),
        events: const Stream.empty(),
      ),
      device: device,
    );
  }

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(CupertinoTabBar),
        matching: find.text('Settings'),
      ),
    );
    await settleSettings(tester);
  }

  Future<void> tapRow(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(find.text(title), 250);
    await settleSettings(tester);
    await tester.tap(find.text(title));
    await settleSettings(tester);
  }

  void lifecycle(WidgetTester tester, bool background) {
    if (background) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    } else {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  }

  testWidgets(
    'onboarding is local, optional lock and model-unavailable continue work',
    (tester) async {
      final device = FakeDeviceProtection();
      final app = await resources(device, onboarding: false);
      await tester.pumpWidget(SekretChatApp(openResources: () async => app));
      await settleSettings(tester);
      expect(find.text('Welcome to Sekret'), findsOneWidget);
      expect(device.requests, 0);
      expect(await app.workspace.history(), isEmpty);
      await tapRow(tester, 'Continue to Sekret');
      expect(find.byType(CupertinoTabBar), findsOneWidget);
      expect((await app.vault.settings.get()).onboardingComplete, isTrue);
      await settings(tester);
      expect(
        find.textContaining('does not support the required on-device model'),
        findsOneWidget,
      );
      await tapRow(tester, 'Refresh storage');
      await tester.pumpWidget(const SizedBox.shrink());
      await settleSettings(tester);
    },
  );

  for (final action in [
    'Delete all chats',
    'Delete entire Knowledge Base',
    'Erase all local data',
  ]) {
    testWidgets(
      '$action cancels safely, then removes only its confirmed scope',
      (tester) async {
        final device = FakeDeviceProtection();
        final app = await resources(device);
        final source = await app.knowledge.importText(
          title: 'Private source',
          text: 'Fictional content retained locally.',
        );
        final chat = await app.workspace.newChat();
        await app.workspace.rename(chat.id, 'Private chat');
        await tester.pumpWidget(SekretChatApp(openResources: () async => app));
        await settleSettings(tester);
        await settings(tester);
        await tapRow(tester, action);
        await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
        await settleSettings(tester);
        expect(await app.workspace.history(), hasLength(1));
        expect(await app.vault.knowledge.list(), hasLength(1));
        expect(device.requests, 0);
        await tapRow(tester, action);
        await tester.tap(
          find.widgetWithText(
            CupertinoDialogAction,
            action.startsWith('Erase') ? 'Erase All' : 'Delete',
          ),
        );
        await settleSettings(tester);
        if (action == 'Delete entire Knowledge Base') {
          expect((await app.workspace.history()).single.id, chat.id);
        } else {
          expect(await app.workspace.history(), isEmpty);
          expect(app.workspace.currentChatId, isNull);
        }
        if (action == 'Delete all chats') {
          expect((await app.vault.knowledge.list()).single.id, source.item.id);
        } else {
          expect(await app.vault.knowledge.list(), isEmpty);
          expect(device.purges, 1);
        }
        expect(device.requests, action.startsWith('Erase') ? 1 : 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await settleSettings(tester);
      },
    );
  }

  testWidgets('Delete all chats stops generation and clears unsent drafts', (
    tester,
  ) async {
    final model = UiModel()..stream = StreamController<String>();
    final app = await resources(FakeDeviceProtection(), model: model);
    await tester.pumpWidget(SekretChatApp(openResources: () async => app));
    await settleSettings(tester);
    final composer = find.byWidgetPredicate(
      (w) => w is CupertinoTextField && w.placeholder == 'Message',
    );
    await tester.enterText(composer, 'Private prompt');
    await settleSettings(tester);
    await tester.tap(find.bySemanticsLabel('Send'));
    await settleSettings(tester);
    model.stream!.add('Private partial answer');
    await settleSettings(tester);
    await tester.enterText(composer, 'Private unsent draft');
    await settleSettings(tester);
    await settings(tester);
    await tapRow(tester, 'Delete all chats');
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Delete'));
    await settleSettings(tester);
    expect(app.engine.isGenerating, isFalse);
    expect(await app.workspace.history(), isEmpty);
    model.stream!.add('Late private answer');
    await tester.tap(
      find.descendant(
        of: find.byType(CupertinoTabBar),
        matching: find.text('Chat'),
      ),
    );
    await settleSettings(tester);
    expect(find.text('Private unsent draft'), findsNothing);
    expect(find.text('Late private answer'), findsNothing);
    expect(
      (await app.workspace.transcript(app.workspace.currentChatId!)),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await settleSettings(tester);
    await tester.runAsync(model.stream!.close);
  });

  testWidgets(
    'Knowledge deletion stops imports and cannot resurrect a late index',
    (tester) async {
      final embedder = UiKnowledgeEmbedder()..gate = Completer<void>();
      final app = await resources(FakeDeviceProtection(), embedder: embedder);
      await app.knowledge.importText(
        title: 'In-flight source',
        text: 'Fictional import still being indexed.',
      );
      await tester.pumpWidget(SekretChatApp(openResources: () async => app));
      await settleSettings(tester);
      await settings(tester);
      await tapRow(tester, 'Delete entire Knowledge Base');
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Delete'));
      await tester.pump(const Duration(milliseconds: 100));
      await expectLater(
        app.knowledge.importText(title: 'Late import', text: 'Not admitted.'),
        throwsStateError,
      );
      embedder.gate!.complete();
      await settleSettings(tester);
      expect(await app.vault.knowledge.list(), isEmpty);
      expect((await app.vault.storageUsage()).knowledgeIndexBytes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleSettings(tester);
    },
  );

  testWidgets('Erase All authentication cancellation preserves data', (
    tester,
  ) async {
    final device = FakeDeviceProtection()..success = false;
    final app = await resources(device);
    await app.workspace.newChat();
    await tester.pumpWidget(SekretChatApp(openResources: () async => app));
    await settleSettings(tester);
    await settings(tester);
    await tapRow(tester, 'Erase all local data');
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Erase All'));
    await settleSettings(tester);
    expect(await app.workspace.history(), hasLength(1));
    expect(device.requests, 1);
    expect(device.purges, 0);
    expect(
      find.textContaining('Authentication was not completed'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await settleSettings(tester);
  });

  testWidgets(
    'cold launch locks, failed auth stays locked, root dialogs cannot bypass resume lock',
    (tester) async {
      final device = FakeDeviceProtection()..success = false;
      final app = await resources(device, lock: true);
      await tester.pumpWidget(SekretChatApp(openResources: () async => app));
      await settleSettings(tester);
      expect(find.text('Sekret is locked'), findsOneWidget);
      expect(find.byType(CupertinoTabBar), findsNothing);
      await tester.tap(find.text('Unlock Sekret'));
      await settleSettings(tester);
      expect(find.text('Sekret is locked'), findsOneWidget);
      device.success = true;
      await tester.tap(find.text('Unlock Sekret'));
      await settleSettings(tester);
      await settings(tester);
      await tapRow(tester, 'Erase all local data');
      // Observe concealment while inactive, when iOS still permits a frame.
      // A live integration runner cannot pump while paused. Do not wait for
      // rendering again until resumed; the native cover is a separate gate.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settleSettings(tester);
      expect(find.text('Erase All').hitTestable(), findsNothing);
      lifecycle(tester, true);
      lifecycle(tester, false);
      await settleSettings(tester);
      expect(find.text('Sekret is locked'), findsOneWidget);
      expect(find.text('Erase All').hitTestable(), findsNothing);
      await tester.tap(find.text('Unlock Sekret'));
      await settleSettings(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleSettings(tester);
    },
  );

  testWidgets(
    'retention previews and cancellation preserve full chats until confirmed',
    (tester) async {
      var now = DateTime.utc(2026, 1, 1);
      final app = await resources(FakeDeviceProtection(), clock: () => now);
      await app.workspace.newChat();
      now = now.add(const Duration(days: 31));
      await tester.pumpWidget(SekretChatApp(openResources: () async => app));
      await settleSettings(tester);
      await settings(tester);
      await tapRow(tester, 'Chat retention');
      await tester.tap(
        find.widgetWithText(
          CupertinoActionSheetAction,
          '30 days after last activity',
        ),
      );
      await settleSettings(tester);
      expect(
        find.textContaining('1 chats will be permanently deleted now'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await settleSettings(tester);
      expect(await app.workspace.history(), hasLength(1));
      await tapRow(tester, 'Chat retention');
      await tester.tap(
        find.widgetWithText(
          CupertinoActionSheetAction,
          '30 days after last activity',
        ),
      );
      await settleSettings(tester);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Apply'));
      await settleSettings(tester);
      expect(await app.workspace.history(), isEmpty);
      expect(
        (await app.vault.settings.get()).retentionPolicy,
        RetentionPolicy.thirtyDays,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await settleSettings(tester);
    },
  );
}
