import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('a new chat starts in General mode without selected sources', () async {
    final vault = await openLocalDataVault(databasePath: ':memory:');
    addTearDown(vault.close);

    final chat = await vault.chats.createChat();
    final chats = await vault.chats.listChats();

    expect(chat.title, 'New Chat');
    expect(chat.mode, ChatMode.general);
    expect(chat.selectedSourceIds, isEmpty);
    expect(chats, hasLength(1));
    expect(chats.single.id, chat.id);
  });

  test(
    'a failed index commit keeps its checkpoint and exposes no evidence',
    () async {
      final vault = await openLocalDataVault(databasePath: ':memory:');
      addTearDown(vault.close);
      final item = await vault.knowledge.beginProcessing(
        title: 'Fictional policy',
        sourceType: KnowledgeSourceType.pdf,
        sourceBytes: Uint8List.fromList([1, 2, 3]),
        fingerprint: 'fictional-policy-v1',
      );
      await vault.knowledge.saveCheckpoint(
        knowledgeItemId: item.id,
        stage: 'embedding',
        completedUnits: 1,
        totalUnits: 2,
        artifact: Uint8List.fromList([4, 5]),
      );

      await expectLater(
        vault.knowledge.completeIndex(
          knowledgeItemId: item.id,
          extractedText: 'First passage. Second passage.',
          passages: [
            EvidencePassageDraft(
              ordinal: 0,
              text: 'First passage.',
              heading: 'ONE',
              page: 1,
              tokenCount: 2,
              vector: Uint8List.fromList([1]),
              vectorScale: 0.1,
            ),
            EvidencePassageDraft(
              ordinal: 0,
              text: 'Second passage.',
              heading: 'TWO',
              page: 2,
              tokenCount: 2,
              vector: Uint8List.fromList([2]),
              vectorScale: 0.1,
            ),
          ],
        ),
        throwsA(isA<VaultWriteException>()),
      );

      final retained = await vault.knowledge.get(item.id);
      expect(retained.processingState, KnowledgeProcessingState.processing);
      expect(retained.checkpoint?.stage, 'embedding');
      expect(await vault.knowledge.listIndexedEvidence(item.id), isEmpty);
    },
  );

  test('a completed index atomically becomes available as evidence', () async {
    final vault = await openLocalDataVault(databasePath: ':memory:');
    addTearDown(vault.close);
    final item = await vault.knowledge.beginProcessing(
      title: 'Fictional handbook',
      sourceType: KnowledgeSourceType.pastedText,
      sourceBytes: Uint8List.fromList([10, 11]),
      sourceName: 'fictional-handbook.txt',
      fingerprint: 'fictional-handbook-v1',
    );
    await vault.knowledge.saveCheckpoint(
      knowledgeItemId: item.id,
      stage: 'indexing',
      completedUnits: 1,
      totalUnits: 1,
      artifact: Uint8List.fromList([12]),
    );

    await vault.knowledge.completeIndex(
      knowledgeItemId: item.id,
      extractedText: 'Leave requests require two days notice.',
      pageCount: 1,
      passages: [
        EvidencePassageDraft(
          ordinal: 0,
          text: 'Leave requests require two days notice.',
          heading: 'LEAVE',
          page: null,
          tokenCount: 7,
          vector: Uint8List.fromList([3, 4]),
          vectorScale: 0.25,
        ),
      ],
    );

    final indexed = await vault.knowledge.get(item.id);
    final evidence = await vault.knowledge.listIndexedEvidence(item.id);
    expect(indexed.processingState, KnowledgeProcessingState.indexed);
    expect(indexed.sourceName, 'fictional-handbook.txt');
    expect(indexed.pageCount, 1);
    expect(indexed.checkpoint, isNull);
    expect(evidence, hasLength(1));
    expect(evidence.single.text, 'Leave requests require two days notice.');
    expect(evidence.single.heading, 'LEAVE');
  });

  test('a turn keeps its original mode, source scope, and evidence', () async {
    final vault = await openLocalDataVault(databasePath: ':memory:');
    addTearDown(vault.close);
    final item = await vault.knowledge.beginProcessing(
      title: 'Fictional benefits guide',
      sourceType: KnowledgeSourceType.pastedText,
      sourceBytes: Uint8List.fromList([20]),
      fingerprint: 'fictional-benefits-v1',
    );
    await vault.knowledge.completeIndex(
      knowledgeItemId: item.id,
      extractedText: 'The fictional allowance is 40 credits.',
      passages: [
        EvidencePassageDraft(
          ordinal: 0,
          text: 'The fictional allowance is 40 credits.',
          heading: 'ALLOWANCE',
          page: null,
          tokenCount: 7,
          vector: Uint8List.fromList([5]),
          vectorScale: 0.5,
        ),
      ],
    );
    final evidence = (await vault.knowledge.listIndexedEvidence(
      item.id,
    )).single;
    final chat = await vault.chats.createChat();
    await vault.chats.updateScope(
      chatId: chat.id,
      mode: ChatMode.knowledgeBase,
      selectedSourceIds: [item.id],
    );

    final turn = await vault.chats.appendTurn(
      chatId: chat.id,
      userText: 'What is the allowance?',
      assistantText: 'The fictional allowance is 40 credits.',
      outcome: TurnOutcome.completed,
      mode: ChatMode.knowledgeBase,
      sourceScopeIds: [item.id],
      evidencePassageIds: [evidence.id],
      citationEvidenceIndexes: [0],
      model: const ModelSnapshot(
        identifier: 'fictional-local-model',
        revision: '1',
        metadata: {'temperature': 0},
      ),
    );
    await vault.chats.updateScope(
      chatId: chat.id,
      mode: ChatMode.general,
      selectedSourceIds: const [],
    );

    final retained = (await vault.chats.listTurns(chat.id)).single;
    expect(retained.id, turn.id);
    expect(retained.provenance.mode, ChatMode.knowledgeBase);
    expect(retained.provenance.sourceScope.single.id, item.id);
    expect(
      retained.provenance.sourceScope.single.title,
      'Fictional benefits guide',
    );
    expect(
      retained.provenance.evidence.single.passageText,
      contains('40 credits'),
    );
    expect(
      retained.provenance.citations.single.evidenceId,
      retained.provenance.evidence.single.id,
    );
    expect(retained.provenance.model.identifier, 'fictional-local-model');
  });

  test('a failed turn commit exposes neither turn nor provenance', () async {
    final vault = await openLocalDataVault(databasePath: ':memory:');
    addTearDown(vault.close);
    final chat = await vault.chats.createChat();

    await expectLater(
      vault.chats.appendTurn(
        chatId: chat.id,
        userText: 'Hello',
        assistantText: 'Hello there.',
        outcome: TurnOutcome.completed,
        mode: ChatMode.general,
        sourceScopeIds: const [],
        evidencePassageIds: const [],
        citationEvidenceIndexes: const [0],
        model: const ModelSnapshot(
          identifier: 'fictional-local-model',
          revision: '1',
        ),
      ),
      throwsA(isA<VaultWriteException>()),
    );

    expect(await vault.chats.listTurns(chat.id), isEmpty);
  });

  test(
    'context summaries and privacy preferences round-trip locally',
    () async {
      final vault = await openLocalDataVault(databasePath: ':memory:');
      addTearDown(vault.close);
      final chat = await vault.chats.createChat();

      await vault.chats.saveContextSummary(
        chatId: chat.id,
        summarizedThroughOrdinal: 7,
        text: 'The user is comparing fictional leave policies.',
      );
      await vault.settings.update(
        retentionPolicy: RetentionPolicy.ninetyDays,
        biometricLockEnabled: true,
        lockDelay: AppLockDelay.oneMinute,
      );

      final summary = await vault.chats.getContextSummary(chat.id);
      final settings = await vault.settings.get();
      expect(summary?.summarizedThroughOrdinal, 7);
      expect(summary?.text, contains('fictional leave policies'));
      expect(settings.retentionPolicy, RetentionPolicy.ninetyDays);
      expect(settings.biometricLockEnabled, isTrue);
      expect(settings.lockDelay, AppLockDelay.oneMinute);
    },
  );

  test(
    'storage accounting is separated and erase all removes user content',
    () async {
      final vault = await openLocalDataVault(databasePath: ':memory:');
      addTearDown(vault.close);
      final item = await vault.knowledge.beginProcessing(
        title: 'Fictional source',
        sourceType: KnowledgeSourceType.pdf,
        sourceBytes: Uint8List.fromList([1, 2, 3, 4]),
        fingerprint: 'erase-all-source-v1',
      );
      await vault.knowledge.completeIndex(
        knowledgeItemId: item.id,
        extractedText: 'Fictional indexed text.',
        passages: [
          EvidencePassageDraft(
            ordinal: 0,
            text: 'Fictional indexed text.',
            heading: 'SOURCE',
            page: 1,
            tokenCount: 3,
            vector: Uint8List.fromList([8, 9]),
            vectorScale: 0.2,
          ),
        ],
      );
      final evidence = (await vault.knowledge.listIndexedEvidence(
        item.id,
      )).single;
      final unfinished = await vault.knowledge.beginProcessing(
        title: 'Unfinished fictional source',
        sourceType: KnowledgeSourceType.photo,
        sourceBytes: Uint8List.fromList([5, 6]),
        fingerprint: 'erase-all-unfinished-v1',
      );
      await vault.knowledge.saveCheckpoint(
        knowledgeItemId: unfinished.id,
        stage: 'ocr',
        completedUnits: 1,
        totalUnits: 3,
        artifact: Uint8List.fromList([7]),
      );
      final chat = await vault.chats.createChat();
      await vault.chats.updateScope(
        chatId: chat.id,
        mode: ChatMode.knowledgeBase,
        selectedSourceIds: [item.id],
      );
      await vault.chats.appendTurn(
        chatId: chat.id,
        userText: 'A private fictional question',
        assistantText: 'A private fictional answer',
        outcome: TurnOutcome.completed,
        mode: ChatMode.knowledgeBase,
        sourceScopeIds: [item.id],
        evidencePassageIds: [evidence.id],
        citationEvidenceIndexes: const [0],
        model: const ModelSnapshot(identifier: 'local', revision: '1'),
      );
      await vault.settings.update(
        retentionPolicy: RetentionPolicy.thirtyDays,
        biometricLockEnabled: true,
        lockDelay: AppLockDelay.immediate,
      );

      final before = await vault.storageUsage();
      expect(before.knowledgeSourceBytes, 6);
      expect(before.knowledgeIndexBytes, greaterThan(4));
      expect(before.chatBytes, greaterThan(20));

      await vault.eraseAll();

      expect(await vault.chats.listChats(), isEmpty);
      expect(await vault.knowledge.list(), isEmpty);
      expect(await vault.storageUsage(), const StorageUsage.zero());
      expect(
        (await vault.settings.get()).retentionPolicy,
        RetentionPolicy.thirtyDays,
      );
    },
  );

  test('a v2 vault reopens without losing its existing records', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sekret-v2-vault-reopen-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}sekret-v2.sqlite3';
    var vault = await openLocalDataVault(databasePath: path);
    final created = await vault.chats.createChat();
    await vault.close();

    vault = await openLocalDataVault(databasePath: path);
    addTearDown(vault.close);

    final chats = await vault.chats.listChats();
    expect(chats, hasLength(1));
    expect(chats.single.id, created.id);
  });

  test(
    'deleting a source retains its chat provenance as source deleted',
    () async {
      final vault = await openLocalDataVault(databasePath: ':memory:');
      addTearDown(vault.close);
      final item = await vault.knowledge.beginProcessing(
        title: 'Fictional deleted source',
        sourceType: KnowledgeSourceType.pastedText,
        sourceBytes: Uint8List.fromList([30]),
        fingerprint: 'deleted-source-v1',
      );
      await vault.knowledge.completeIndex(
        knowledgeItemId: item.id,
        extractedText: 'A fictional retained fact.',
        passages: [
          EvidencePassageDraft(
            ordinal: 0,
            text: 'A fictional retained fact.',
            heading: 'FACT',
            page: null,
            tokenCount: 4,
            vector: Uint8List.fromList([7]),
            vectorScale: 1,
          ),
        ],
      );
      final evidence = (await vault.knowledge.listIndexedEvidence(
        item.id,
      )).single;
      final chat = await vault.chats.createChat();
      await vault.chats.updateScope(
        chatId: chat.id,
        mode: ChatMode.knowledgeBase,
        selectedSourceIds: [item.id],
      );
      await vault.chats.appendTurn(
        chatId: chat.id,
        userText: 'What is the fact?',
        assistantText: 'A fictional retained fact.',
        outcome: TurnOutcome.completed,
        mode: ChatMode.knowledgeBase,
        sourceScopeIds: [item.id],
        evidencePassageIds: [evidence.id],
        citationEvidenceIndexes: const [0],
        model: const ModelSnapshot(identifier: 'local', revision: '1'),
      );

      await vault.knowledge.delete(item.id);

      final retainedChat = (await vault.chats.listChats()).single;
      final retainedTurn = (await vault.chats.listTurns(chat.id)).single;
      expect(retainedChat.selectedSourceIds, isEmpty);
      expect(retainedTurn.assistantText, 'A fictional retained fact.');
      expect(retainedTurn.provenance.sourceScope.single.sourceDeleted, isTrue);
      expect(retainedTurn.provenance.evidence.single.sourceDeleted, isTrue);
      expect(retainedTurn.provenance.citations, hasLength(1));
      expect(await vault.knowledge.list(), isEmpty);
    },
  );

  test(
    'schema 5 upgrades onboarding without resetting content or security',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-settings-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/vault.sqlite3';
      var vault = await openLocalDataVault(databasePath: path);
      final chat = await vault.chats.createChat();
      await vault.settings.update(
        retentionPolicy: RetentionPolicy.ninetyDays,
        biometricLockEnabled: true,
        lockDelay: AppLockDelay.fifteenMinutes,
      );
      await vault.close();
      final old = sqlite3.open(path);
      old.execute(
        'ALTER TABLE vault_settings DROP COLUMN onboarding_complete; PRAGMA user_version = 5;',
      );
      old.close();
      vault = await openLocalDataVault(databasePath: path);
      addTearDown(vault.close);
      expect((await vault.chats.listChats()).single.id, chat.id);
      final settings = await vault.settings.get();
      expect(settings.retentionPolicy, RetentionPolicy.ninetyDays);
      expect(settings.biometricLockEnabled, isTrue);
      expect(settings.lockDelay, AppLockDelay.fifteenMinutes);
      expect(settings.onboardingComplete, isFalse);
    },
  );

  test('a newer schema is rejected without changing its data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sekret-v2-vault-future-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}sekret-v2.sqlite3';
    final futureDatabase = sqlite3.open(path);
    futureDatabase.execute('''
      CREATE TABLE future_records (value TEXT NOT NULL);
      INSERT INTO future_records (value) VALUES ('preserve me');
      PRAGMA user_version = 999;
    ''');
    futureDatabase.close();
    final before = await File(path).readAsBytes();

    await expectLater(
      openLocalDataVault(databasePath: path),
      throwsA(
        isA<UnsupportedVaultSchemaException>()
            .having((error) => error.foundVersion, 'found version', 999)
            .having(
              (error) => error.supportedVersion,
              'supported version',
              localDataVaultSchemaVersion,
            ),
      ),
    );

    expect(await File(path).readAsBytes(), before);
    final preserved = sqlite3.open(path);
    addTearDown(preserved.close);
    expect(
      preserved.select('SELECT value FROM future_records;').single['value'],
      'preserve me',
    );
  });

  test('an unversioned v1 database requires an explicit reset', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sekret-v2-vault-v1-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}sekret.sqlite3';
    final v1Database = sqlite3.open(path);
    v1Database.execute('''
      CREATE TABLE documents (id TEXT PRIMARY KEY, title TEXT NOT NULL);
      INSERT INTO documents (id, title) VALUES ('v1', 'Preserve until reset');
    ''');
    v1Database.close();

    await expectLater(
      openLocalDataVault(databasePath: path),
      throwsA(
        isA<UnrecognizedVaultSchemaException>().having(
          (error) => error.existingTables,
          'existing tables',
          contains('documents'),
        ),
      ),
    );

    final preserved = sqlite3.open(path);
    addTearDown(preserved.close);
    expect(
      preserved.select('SELECT title FROM documents;').single['title'],
      'Preserve until reset',
    );
    expect(
      preserved.select("SELECT name FROM sqlite_schema WHERE name = 'chats';"),
      isEmpty,
    );
  });
}
