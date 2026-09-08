import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sqlite3/sqlite3.dart';

const model = ModelSnapshot(identifier: 'test-local', revision: '1');

void main() {
  late DateTime now;
  late LocalDataVault vault;
  late ChatWorkspace workspace;
  final temporaryDirectories = <Directory>[];
  setUp(() async {
    now = DateTime.utc(2026, 1, 1);
    vault = await openLocalDataVault(
      databasePath: ':memory:',
      clock: () => now,
    );
    workspace = await ChatWorkspace.open(vault, clock: () => now);
  });
  tearDown(() async {
    await workspace.dispose();
    await vault.close();
    for (final directory in temporaryDirectories) {
      await directory.delete(recursive: true);
    }
    temporaryDirectories.clear();
  });

  Future<TurnRecord> say(String chatId, String question, String answer) async {
    final turn = await workspace.beginTurn(
      chatId: chatId,
      userText: question,
      model: model,
    );
    await workspace.saveResponse(
      turn.id,
      answer,
      outcome: TurnOutcome.completed,
    );
    return turn;
  }

  test(
    'history is isolated, automatically titled, renameable and searchable',
    () async {
      final first = await workspace.newChat();
      await say(
        first.id,
        '  Plan\n my   holiday  ',
        'Visit the fictional observatory',
      );
      final second = await workspace.newChat();
      expect(second.mode, ChatMode.general);
      expect(second.selectedSourceIds, isEmpty);
      expect(await workspace.transcript(second.id), isEmpty);
      expect((await workspace.context(second.id)).summary, isNull);
      expect(
        (await workspace.history(query: 'PLAN MY')).single.title,
        'Plan my holiday',
      );
      expect(
        (await workspace.history(query: 'OBSERVATORY')).single.id,
        first.id,
      );
      await workspace.rename(first.id, 'Winter break');
      await say(first.id, 'More ideas', 'Visit the museum');
      expect(
        (await workspace.history(query: 'winter')).single.title,
        'Winter break',
      );
      expect(await workspace.history(query: '%'), isEmpty);
      await workspace.openChat(first.id);
      expect(workspace.currentChatId, first.id);
    },
  );

  test(
    'summary refresh never replaces transcript and truncation invalidates it',
    () async {
      final chat = await workspace.newChat();
      final turns = <TurnRecord>[];
      for (var i = 0; i < 7; i++) {
        turns.add(await say(chat.id, 'Question $i', 'Answer $i'));
      }
      final context = await workspace.context(chat.id);
      expect(context.summary?.summarizedThroughOrdinal, 2);
      expect(context.summary?.text, contains('Question 2'));
      expect(context.recentTurns.map((t) => t.ordinal), [3, 4, 5, 6]);
      expect(await workspace.transcript(chat.id), hasLength(7));
      await say(chat.id, 'Question 7', 'Answer 7');
      expect(
        (await workspace.context(chat.id)).summary?.summarizedThroughOrdinal,
        3,
      );
      await workspace.deleteFromTurn(chat.id, turns[2].id);
      expect((await workspace.transcript(chat.id)).map((t) => t.ordinal), [
        0,
        1,
      ]);
      expect((await workspace.context(chat.id)).summary, isNull);
      expect(await vault.chats.getContextSummary(chat.id), isNull);
      await expectLater(
        workspace.deleteFromTurn(chat.id, turns[6].id),
        throwsStateError,
      );
      expect(await workspace.transcript(chat.id), hasLength(2));
    },
  );

  test(
    'delete hides the chat immediately, Undo expires at five seconds',
    () async {
      final first = await workspace.newChat();
      await say(first.id, 'Private question', 'Private answer');
      await workspace.deleteChat(first.id);
      expect(await workspace.history(query: 'Private'), isEmpty);
      await expectLater(workspace.openChat(first.id), throwsStateError);
      now = now.add(const Duration(seconds: 4));
      expect(await workspace.undoDelete(first.id), isTrue);
      expect(await workspace.transcript(first.id), hasLength(1));
      await workspace.deleteChat(first.id);
      now = now.add(const Duration(seconds: 5));
      expect(await workspace.undoDelete(first.id), isFalse);
      expect(await workspace.history(), isEmpty);
      expect(await vault.storageUsage(), const StorageUsage.zero());
    },
  );

  test(
    'retention previews do not delete and confirmation excludes changed chats',
    () async {
      final old = await workspace.newChat();
      await say(old.id, 'Old message', 'Old answer');
      now = now.add(
        const Duration(days: 29, hours: 23, minutes: 59, seconds: 59),
      );
      expect(
        (await workspace.previewRetention(
          RetentionPolicy.thirtyDays,
        )).affectedChats,
        0,
      );
      now = now.add(const Duration(seconds: 1));
      final preview = await workspace.previewRetention(
        RetentionPolicy.thirtyDays,
      );
      expect(preview.affectedChats, 1);
      expect(await workspace.history(), hasLength(1));
      await workspace.rename(old.id, 'Active again');
      await workspace.confirmRetention(preview);
      expect(await workspace.history(), hasLength(1));
      await expectLater(workspace.confirmRetention(preview), throwsStateError);
      now = now.add(const Duration(days: 30));
      await workspace.resume();
      expect(await workspace.history(), isEmpty);
      expect(await vault.storageUsage(), const StorageUsage.zero());
    },
  );

  test(
    'manual retention preserves chats; ninety days reaps whole chats at boundary',
    () async {
      final chat = await workspace.newChat();
      await say(chat.id, 'Keep me', 'Full transcript');
      now = now.add(const Duration(days: 89));
      await workspace.resume();
      expect(await workspace.history(), hasLength(1));
      await workspace.confirmRetention(
        await workspace.previewRetention(RetentionPolicy.ninetyDays),
      );
      await workspace.resume();
      expect(await workspace.transcript(chat.id), hasLength(1));
      now = now.add(const Duration(days: 1));
      await workspace.resume();
      expect(await workspace.history(), isEmpty);
    },
  );

  test(
    'one turn may generate globally; suspension preserves partial response',
    () async {
      final first = await workspace.newChat();
      final pending = await workspace.beginTurn(
        chatId: first.id,
        userText: 'Hello',
        model: model,
      );
      await workspace.saveResponse(pending.id, 'Partial response');
      final second = await workspace.newChat();
      await expectLater(
        workspace.beginTurn(
          chatId: second.id,
          userText: 'Another',
          model: model,
        ),
        throwsA(isA<VaultWriteException>()),
      );
      expect(await workspace.transcript(second.id), isEmpty);
      await workspace.suspend();
      final recovered = (await workspace.transcript(first.id)).single;
      expect(recovered.outcome, TurnOutcome.interrupted);
      expect(recovered.assistantText, 'Partial response');
      await expectLater(
        workspace.saveResponse(
          pending.id,
          'Late completion',
          outcome: TurnOutcome.completed,
        ),
        throwsStateError,
      );
      await say(second.id, 'New request', 'New answer');
    },
  );

  test(
    'deleting an active turn rejects late output without reviving it',
    () async {
      final chat = await workspace.newChat();
      final pending = await workspace.beginTurn(
        chatId: chat.id,
        userText: 'Hello',
        model: model,
      );
      await workspace.deleteFromTurn(chat.id, pending.id);
      await expectLater(
        workspace.saveResponse(pending.id, 'Late answer'),
        throwsStateError,
      );
      expect(await workspace.transcript(chat.id), isEmpty);
    },
  );

  test(
    'reopen recovers partial turns and preserves pending Undo deadline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-chat-restart-',
      );
      temporaryDirectories.add(directory);
      final path = '${directory.path}/vault.sqlite3';
      await workspace.dispose();
      await vault.close();
      vault = await openLocalDataVault(databasePath: path, clock: () => now);
      workspace = await ChatWorkspace.open(vault, clock: () => now);
      final active = await workspace.newChat();
      final pending = await workspace.beginTurn(
        chatId: active.id,
        userText: 'Question',
        model: model,
      );
      await workspace.saveResponse(pending.id, 'Saved partial');
      final removed = await workspace.newChat();
      await workspace.deleteChat(removed.id);
      await workspace.dispose();
      await vault.close();
      now = now.add(const Duration(seconds: 2));
      vault = await openLocalDataVault(databasePath: path, clock: () => now);
      workspace = await ChatWorkspace.open(vault, clock: () => now);
      expect(
        (await workspace.transcript(active.id)).single.outcome,
        TurnOutcome.interrupted,
      );
      expect(
        (await workspace.transcript(active.id)).single.assistantText,
        'Saved partial',
      );
      expect(await workspace.undoDelete(removed.id), isTrue);
      await workspace.deleteChat(removed.id);
      await workspace.dispose();
      await vault.close();
      now = now.add(const Duration(seconds: 5));
      vault = await openLocalDataVault(databasePath: path, clock: () => now);
      workspace = await ChatWorkspace.open(vault, clock: () => now);
      expect(await workspace.undoDelete(removed.id), isFalse);
      expect((await workspace.history()).single.id, active.id);
    },
  );

  test(
    'migration from schema one preserves records; failure rolls back',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-chat-migration-',
      );
      temporaryDirectories.add(directory);
      final path = '${directory.path}/vault.sqlite3';
      final original = await openLocalDataVault(databasePath: path);
      final chat = await original.chats.createChat();
      await original.close();
      // Reconstruct the previous released schema at its file boundary.
      var database = sqlite3.open(path);
      database.execute('''
      DROP INDEX one_generating_turn;
      DROP INDEX chat_activity;
      DROP TABLE chat_workspace_state;
      ALTER TABLE chats DROP COLUMN revision;
      ALTER TABLE chats DROP COLUMN manually_titled;
      ALTER TABLE chats DROP COLUMN deletion_deadline;
      ALTER TABLE turns DROP COLUMN failure;
      ALTER TABLE turn_provenance DROP COLUMN evidence_captured;
      DROP TABLE knowledge_pages;
      ALTER TABLE knowledge_items DROP COLUMN processing_message;
      PRAGMA user_version = 1;
    ''');
      database.close();
      final migrated = await openLocalDataVault(databasePath: path);
      expect((await migrated.chats.listChats()).single.id, chat.id);
      await migrated.chats.renameChat(chat.id, 'Migrated');
      await migrated.close();
      database = sqlite3.open(path);
      // A malformed prior schema triggers a real DDL failure.
      database.execute('''
      ALTER TABLE chats DROP COLUMN manually_titled;
      PRAGMA user_version = 1;
    ''');
      database.close();
      final before = await File(path).readAsBytes();
      await expectLater(
        openLocalDataVault(databasePath: path),
        throwsA(isA<SqliteException>()),
      );
      expect(await File(path).readAsBytes(), before);
    },
  );

  test('Undo deadline permanently reaps without another user action', () async {
    await workspace.dispose();
    workspace = await ChatWorkspace.open(
      vault,
      clock: () => now,
      undoWindow: const Duration(milliseconds: 20),
    );
    final chat = await workspace.newChat();
    await say(chat.id, 'Question', 'Answer');
    await workspace.deleteChat(chat.id);
    now = now.add(const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(await vault.storageUsage(), const StorageUsage.zero());
    expect(await workspace.undoDelete(chat.id), isFalse);
  });

  test(
    'turn scope is captured at start and retained after mode changes',
    () async {
      final source = await vault.knowledge.beginProcessing(
        title: 'Fictional source',
        sourceType: KnowledgeSourceType.pastedText,
        sourceBytes: Uint8List.fromList([1]),
        fingerprint: 'scope-test',
      );
      final chat = await workspace.newChat();
      await workspace.changeScope(chat.id, ChatMode.knowledgeBase, [source.id]);
      await expectLater(
        workspace.beginTurn(chatId: chat.id, userText: 'What?', model: model),
        throwsStateError,
      );
      expect(await workspace.transcript(chat.id), isEmpty);
      await vault.knowledge.completeIndex(
        knowledgeItemId: source.id,
        extractedText: 'Fictional text',
        passages: [
          EvidencePassageDraft(
            ordinal: 0,
            text: 'Fictional text',
            heading: '',
            page: null,
            tokenCount: 2,
            vector: Uint8List.fromList([1]),
            vectorScale: 1,
          ),
        ],
      );
      final turn = await workspace.beginTurn(
        chatId: chat.id,
        userText: 'What?',
        model: model,
      );
      await workspace.changeScope(chat.id, ChatMode.general, []);
      await workspace.saveResponse(
        turn.id,
        'Interrupted',
        outcome: TurnOutcome.stopped,
      );
      final stored = (await workspace.transcript(chat.id)).single;
      expect(stored.provenance.mode, ChatMode.knowledgeBase);
      expect(stored.provenance.sourceScope.single.id, source.id);
      final next = await workspace.beginTurn(
        chatId: chat.id,
        userText: 'Hello',
        model: model,
      );
      expect(next.provenance.mode, ChatMode.general);
      expect(next.provenance.sourceScope, isEmpty);
    },
  );

  test(
    'current chat and summaries survive reopen independently of history order',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-chat-context-',
      );
      temporaryDirectories.add(directory);
      final path = '${directory.path}/vault.sqlite3';
      await workspace.dispose();
      await vault.close();
      vault = await openLocalDataVault(databasePath: path, clock: () => now);
      workspace = await ChatWorkspace.open(vault, clock: () => now);
      final first = await workspace.newChat();
      for (var i = 0; i < 20; i++) {
        await say(
          first.id,
          'Earlier $i ${'🐈' * 200}',
          'Answer $i ${'猫' * 200}',
        );
      }
      final before = await workspace.context(first.id);
      expect(before.summary!.text.runes.length, lessThan(3000));
      now = now.add(const Duration(days: 1));
      final second = await workspace.newChat();
      await say(second.id, 'Different chat', 'Different answer');
      await workspace.openChat(first.id);
      await workspace.dispose();
      await vault.close();
      vault = await openLocalDataVault(databasePath: path, clock: () => now);
      workspace = await ChatWorkspace.open(vault, clock: () => now);
      expect(workspace.currentChatId, first.id);
      expect((await workspace.history()).first.id, second.id);
      expect(
        (await workspace.context(first.id)).summary!.text,
        before.summary!.text,
      );
      expect(await workspace.transcript(first.id), hasLength(20));
      expect((await workspace.context(second.id)).summary, isNull);
      now = now.add(const Duration(days: 400));
      await workspace.resume();
      expect(await workspace.history(), hasLength(2));
    },
  );
}
