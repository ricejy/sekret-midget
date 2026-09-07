import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/chat/general_chat_engine.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/core/platform/token_counter.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late LocalDataVault vault;
  late ChatWorkspace workspace;
  late FakeGeneralModel model;
  late GeneralChatEngine engine;
  GeneralChatEngine makeEngine() => GeneralChatEngine(
    workspace: workspace,
    backend: model,
    contextProbe: model,
    model: const ModelSnapshot(identifier: 'fake-local', revision: '1'),
  );
  setUp(() async {
    vault = await openLocalDataVault(databasePath: ':memory:');
    workspace = await ChatWorkspace.open(vault);
    model = FakeGeneralModel();
    engine = makeEngine();
  });
  tearDown(() async {
    await engine.dispose();
    await workspace.dispose();
    await vault.close();
  });

  test('General mode never touches the Knowledge Base facade', () async {
    await engine.dispose();
    await workspace.dispose();
    final chatOnly = ChatOnlyVault(vault);
    workspace = await ChatWorkspace.open(chatOnly);
    engine = makeEngine();
    final chat = await workspace.newChat();
    final first = await engine.send(chatId: chat.id, text: 'Hello');
    expect(first.turn.outcome, TurnOutcome.completed);
    expect(
      (await engine.regenerate(
        chatId: chat.id,
        turnId: first.turn.id,
      )).turn.outcome,
      TurnOutcome.completed,
    );
    expect(chatOnly.knowledgeReads, 0);
  });

  test(
    'an error racing immediate Stop does not escape or fabricate failure',
    () async {
      final chat = await workspace.newChat();
      model.availabilityGate = Completer<LlmAvailability>();
      final pending = engine.send(chatId: chat.id, text: 'Hello');
      final stopped = engine.stop();
      // Let turn admission enter preflight while its cancellation is already set.
      await Future<void>.delayed(Duration.zero);
      model.availabilityGate!.completeError(
        const LlmException(LlmFailureCode.unavailable, 'PRIVATE DETAIL'),
      );
      await stopped;
      expect((await pending).turn.outcome, TurnOutcome.stopped);
    },
  );

  test(
    'General answers persist with no sources and only current-chat context',
    () async {
      final a = await workspace.newChat();
      await engine.send(chatId: a.id, text: 'Secret from chat A');
      final b = await workspace.newChat();
      await engine.send(chatId: b.id, text: 'My name is Bea');
      final result = await engine.send(chatId: b.id, text: 'What is my name?');
      expect(model.prompts.last, contains('My name is Bea'));
      expect(model.prompts.last, isNot(contains('Secret from chat A')));
      expect(result.turn.answerLabel, 'General answer');
      expect(result.turn.outcome, TurnOutcome.completed);
      expect(result.turn.assistantText, 'A local answer.');
      expect(result.turn.provenance.mode, ChatMode.general);
      expect(result.turn.provenance.sourceScope, isEmpty);
      expect(result.turn.provenance.evidence, isEmpty);
      expect(result.turn.provenance.citations, isEmpty);
      expect(
        result.turn.provenance.model.metadata['promptVersion'],
        generalPromptVersion,
      );
      final prompt = jsonDecode(model.prompts.last) as Map;
      expect((prompt['recent_turns'] as List).length, 1);
    },
  );

  test(
    'bounded summary and recent turns keep the visible transcript intact',
    () async {
      final chat = await workspace.newChat();
      for (var i = 0; i < 7; i++) {
        await engine.send(chatId: chat.id, text: 'Message $i');
      }
      final result = await engine.send(chatId: chat.id, text: 'Continue');
      expect(result.earlierContextSummarized, isTrue);
      final prompt = jsonDecode(model.prompts.last) as Map;
      expect(prompt['context_summary'], contains('Message 0'));
      expect((prompt['recent_turns'] as List).length, 4);
      expect(await workspace.transcript(chat.id), hasLength(8));
    },
  );

  test('busy submissions across chats are rejected, not queued', () async {
    final a = await workspace.newChat();
    final b = await workspace.newChat();
    model.hold();
    final first = engine.send(chatId: a.id, text: 'First');
    await expectLater(
      engine.send(chatId: b.id, text: 'Second'),
      throwsStateError,
    );
    await model.started.future;
    final otherEngine = makeEngine();
    await expectLater(
      otherEngine.send(chatId: b.id, text: 'Third'),
      throwsA(isA<VaultWriteException>()),
    );
    await otherEngine.dispose();
    await engine.stop();
    expect((await first).turn.outcome, TurnOutcome.stopped);
    expect(await workspace.transcript(b.id), isEmpty);
    expect(model.prompts, hasLength(1));
  });

  test(
    'Stop cancels a silent model and does not fabricate completion',
    () async {
      final chat = await workspace.newChat();
      model.hold();
      final pending = engine.send(chatId: chat.id, text: 'Hello');
      await model.started.future;
      await engine.stop().timeout(const Duration(seconds: 2));
      final result = await pending;
      expect(model.cancelled, isTrue);
      expect(result.turn.outcome, TurnOutcome.stopped);
      expect(result.turn.assistantText, isEmpty);
      expect(engine.isGenerating, isFalse);
    },
  );

  test('Stop during availability records an empty terminal turn', () async {
    final chat = await workspace.newChat();
    model.availabilityGate = Completer<LlmAvailability>();
    final pending = engine.send(chatId: chat.id, text: 'Hello');
    await engine.stop().timeout(const Duration(seconds: 2));
    expect((await pending).turn.outcome, TurnOutcome.stopped);
    model.availabilityGate!.complete(const Available());
    expect(model.prompts, isEmpty);
  });

  test(
    'suspension preserves cumulative partial text and allows recovery',
    () async {
      final chat = await workspace.newChat();
      model.hold();
      final pending = engine.send(chatId: chat.id, text: 'Hello');
      await model.started.future;
      final saved = workspace.changes.firstWhere((_) => model.emitted);
      model.emitted = true;
      model.controller!.add('Partial answer');
      await saved;
      await engine.suspend();
      final result = await pending;
      expect(result.turn.outcome, TurnOutcome.interrupted);
      expect(result.turn.assistantText, 'Partial answer');
      await expectLater(
        engine.send(chatId: chat.id, text: 'Blocked'),
        throwsStateError,
      );
      await engine.resume();
      model.controller = null;
      final regenerated = await engine.regenerate(
        chatId: chat.id,
        turnId: result.turn.id,
      );
      expect(regenerated.turn.outcome, TurnOutcome.completed);
    },
  );

  test(
    'regenerate uses original General mode and context before original',
    () async {
      final chat = await workspace.newChat();
      await engine.send(chatId: chat.id, text: 'Earlier turn');
      final original = await engine.send(
        chatId: chat.id,
        text: 'Original question',
      );
      await engine.send(chatId: chat.id, text: 'Later secret');
      await workspace.changeScope(chat.id, ChatMode.knowledgeBase, []);
      final result = await engine.regenerate(
        chatId: chat.id,
        turnId: original.turn.id,
      );
      expect(result.turn.userText, 'Original question');
      expect(result.turn.provenance.mode, ChatMode.general);
      expect(model.prompts.last, contains('Earlier turn'));
      expect(model.prompts.last, isNot(contains('Later secret')));
      expect((await workspace.history()).single.mode, ChatMode.knowledgeBase);
      expect(await workspace.transcript(chat.id), hasLength(4));
      await expectLater(
        engine.send(chatId: chat.id, text: 'Not general'),
        throwsStateError,
      );
    },
  );

  test('all unavailable states remain distinct and can be retried', () async {
    final chat = await workspace.newChat();
    for (final (availability, failure) in [
      (const DeviceNotEligible(), TurnFailure.deviceNotEligible),
      (
        const AppleIntelligenceNotEnabled(),
        TurnFailure.appleIntelligenceNotEnabled,
      ),
      (const ModelNotReady(), TurnFailure.modelNotReady),
    ]) {
      model.status = availability;
      final result = await engine.send(chatId: chat.id, text: 'Hello');
      expect(result.turn.outcome, TurnOutcome.failed);
      expect(result.turn.failure, failure);
      expect(result.turn.assistantText, isEmpty);
    }
    expect(model.prompts, isEmpty);
    model.status = const Available();
    expect(
      (await engine.send(chatId: chat.id, text: 'Retry')).turn.outcome,
      TurnOutcome.completed,
    );
  });

  test(
    'exact budget includes instructions, current prompt and output reserve',
    () async {
      final chat = await workspace.newChat();
      model.window = 739; // 50 instructions + 50 prompt + 640 reserve = 740.
      final result = await engine.send(chatId: chat.id, text: 'Too long');
      expect(result.turn.failure, TurnFailure.contextOverflow);
      expect(model.countedInstructions, generalInstructions);
      expect(model.countedPrompt, contains('Too long'));
      expect(model.prompts, isEmpty);
      model.window = 740;
      expect(
        (await engine.send(chatId: chat.id, text: 'Fits')).turn.outcome,
        TurnOutcome.completed,
      );
    },
  );

  test(
    'stream errors retain partial text and sanitized typed failures',
    () async {
      final chat = await workspace.newChat();
      for (final (code, failure) in [
        (LlmFailureCode.unavailable, TurnFailure.unavailable),
        (LlmFailureCode.contextOverflow, TurnFailure.contextOverflow),
        (LlmFailureCode.guardrailViolation, TurnFailure.guardrailViolation),
        (LlmFailureCode.streamFailure, TurnFailure.streamFailure),
      ]) {
        model.error = LlmException(code, 'PRIVATE ERROR DATA');
        final result = await engine.send(chatId: chat.id, text: 'Hello');
        expect(result.turn.outcome, TurnOutcome.failed);
        expect(result.turn.failure, failure);
        expect(result.turn.assistantText, 'A local answer.');
        expect(result.turn.assistantText, isNot(contains('PRIVATE')));
      }
    },
  );

  test('an empty successful stream is a failure, not an answer', () async {
    final chat = await workspace.newChat();
    model.empty = true;
    expect(
      (await engine.send(chatId: chat.id, text: 'Hello')).turn.failure,
      TurnFailure.streamFailure,
    );
  });

  test(
    'native interruption preserves partial response as interrupted',
    () async {
      final chat = await workspace.newChat();
      model.error = const LlmException(
        LlmFailureCode.interrupted,
        'Interrupted',
      );
      final result = await engine.send(chatId: chat.id, text: 'Hello');
      expect(result.turn.outcome, TurnOutcome.interrupted);
      expect(result.turn.failure, isNull);
      expect(result.turn.assistantText, 'A local answer.');
    },
  );

  test(
    'General guidance includes contextual caution without topic refusal',
    () {
      for (final topic in ['legal', 'medical', 'financial']) {
        expect(generalInstructions, contains(topic));
      }
      expect(generalInstructions, contains('brief, contextual caution'));
      expect(
        generalInstructions,
        contains('do not refuse merely because of the topic'),
      );
    },
  );

  test(
    'schema 2 migrates preserving turns and persists failure after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-general-',
      );
      final path = '${directory.path}/vault.sqlite3';
      try {
        await engine.dispose();
        await workspace.dispose();
        await vault.close();
        vault = await openLocalDataVault(databasePath: path);
        workspace = await ChatWorkspace.open(vault);
        engine = makeEngine();
        final chat = await workspace.newChat();
        await engine.send(chatId: chat.id, text: 'Preserved');
        await engine.dispose();
        await workspace.dispose();
        await vault.close();
        final old = sqlite3.open(path);
        old.execute(
          'ALTER TABLE turns DROP COLUMN failure; DROP TABLE knowledge_pages; '
          'ALTER TABLE knowledge_items DROP COLUMN processing_message; PRAGMA user_version = 2;',
        );
        old.close();
        vault = await openLocalDataVault(databasePath: path);
        workspace = await ChatWorkspace.open(vault);
        engine = makeEngine();
        model.status = const AppleIntelligenceNotEnabled();
        await engine.send(chatId: chat.id, text: 'Unavailable');
        await engine.dispose();
        await workspace.dispose();
        await vault.close();
        vault = await openLocalDataVault(databasePath: path);
        workspace = await ChatWorkspace.open(vault);
        engine = makeEngine();
        final turns = await workspace.transcript(chat.id);
        expect(turns.first.assistantText, 'A local answer.');
        expect(turns.last.failure, TurnFailure.appleIntelligenceNotEnabled);
      } finally {
        await engine.dispose();
        await workspace.dispose();
        await vault.close();
        await directory.delete(recursive: true);
        vault = await openLocalDataVault(databasePath: ':memory:');
        workspace = await ChatWorkspace.open(vault);
        engine = makeEngine();
      }
    },
  );
}

final class FakeGeneralModel implements GeneralLlmBackend, ModelContextProbe {
  LlmAvailability status = const Available();
  Completer<LlmAvailability>? availabilityGate;
  final prompts = <String>[];
  final started = Completer<void>();
  StreamController<String>? controller;
  bool cancelled = false;
  bool emitted = false;
  bool empty = false;
  LlmException? error;
  int window = 4096;
  String? countedInstructions;
  String? countedPrompt;
  void hold() {
    controller = StreamController<String>(
      onCancel: () {
        cancelled = true;
      },
    );
  }

  @override
  Future<LlmAvailability> availability() async =>
      availabilityGate == null ? status : availabilityGate!.future;
  @override
  Stream<String> generateGeneral({required String prompt}) {
    prompts.add(prompt);
    if (!started.isCompleted) started.complete();
    return controller?.stream ?? response();
  }

  Stream<String> response() async* {
    if (!empty) yield 'A local answer.';
    if (error != null) throw error!;
  }

  @override
  Future<int> contextWindowSize() async => window;
  @override
  Future<int> countInstructionTokens(String instructions) async {
    countedInstructions = instructions;
    return 50;
  }

  @override
  Future<int> countPromptTokens(String prompt) async {
    countedPrompt = prompt;
    return 50;
  }
}

final class ChatOnlyVault implements LocalDataVault {
  ChatOnlyVault(this.delegate);
  final LocalDataVault delegate;
  int knowledgeReads = 0;
  @override
  VaultChats get chats => delegate.chats;
  @override
  VaultKnowledge get knowledge {
    knowledgeReads++;
    throw StateError('General chat must never query knowledge.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
