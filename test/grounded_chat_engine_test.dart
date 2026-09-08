import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_engine.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/knowledge/knowledge_base.dart';
import 'package:sekret_midget/core/platform/embedder.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';
import 'package:sekret_midget/core/platform/token_counter.dart';
import 'package:sekret_midget/core/question/document_question_service.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sqlite3/sqlite3.dart';

void main() => registerGroundedChatTests();

void registerGroundedChatTests({
  void Function(String, Future<void> Function())? testCase,
}) {
  final runTest =
      testCase ??
      (String name, Future<void> Function() body) {
        test(name, body);
      };
  late LocalDataVault vault;
  late ChatWorkspace workspace;
  late KnowledgeBase knowledge;
  late QueryEmbedder embedder;
  late GroundedModel model;
  late ChatEngine engine;
  Future<void> compose() async {
    workspace = await ChatWorkspace.open(vault);
    knowledge = await KnowledgeBase.open(
      vault: vault,
      embedder: embedder,
      tokenCounter: const FakeTokenCounter(),
    );
    engine = ChatEngine(
      workspace: workspace,
      backend: model,
      contextProbe: model,
      groundedBackend: model,
      knowledgeBase: knowledge,
      model: const ModelSnapshot(identifier: 'fixture-local', revision: '1'),
    );
  }

  setUp(() async {
    vault = await openLocalDataVault(databasePath: ':memory:');
    model = GroundedModel();
    embedder = QueryEmbedder();
    await compose();
  });
  tearDown(() async {
    await engine.dispose();
    await knowledge.dispose();
    await workspace.dispose();
    await vault.close();
  });
  Future<String> source(String title, String text, {bool empty = false}) async {
    final item = await vault.knowledge.beginProcessing(
      title: title,
      sourceType: KnowledgeSourceType.pdf,
      sourceBytes: Uint8List.fromList([1]),
      fingerprint: title,
    );
    await vault.knowledge.completeIndex(
      knowledgeItemId: item.id,
      extractedText: text,
      pageCount: 2,
      passages: empty
          ? []
          : [
              EvidencePassageDraft(
                ordinal: 0,
                text: text,
                heading: 'RETURN POLICY',
                page: 2,
                tokenCount: 20,
                vector: Uint8List.fromList([127, 0]),
                vectorScale: 1 / 127,
              ),
            ],
    );
    return item.id;
  }

  Future<String> chat(List<String> sources) async {
    final chat = await workspace.newChat();
    await workspace.changeScope(chat.id, ChatMode.knowledgeBase, sources);
    return chat.id;
  }

  runTest(
    'multiple sources are sealed before generation with complete source cards',
    () async {
      final a = await source('Aster', 'Aster returns equipment within 7 days.');
      final b = await source(
        'Birch',
        'Birch returns equipment within 14 days.',
      );
      await source('Excluded', 'Excluded returns equipment within 999 days.');
      final id = await chat([a, b]);
      model.beforeAnswer = () async {
        final pending = (await workspace.transcript(id)).single;
        expect(pending.outcome, TurnOutcome.generating);
        expect(pending.provenance.evidence, hasLength(2));
        expect(pending.provenance.citations, hasLength(2));
      };
      final result = await engine.send(
        chatId: id,
        text: 'Compare equipment return deadlines.',
      );
      expect(result.turn.outcome, TurnOutcome.completed);
      expect(result.turn.answerLabel, 'Based on selected sources');
      expect(
        result.turn.provenance.model.metadata['promptVersion'],
        groundedPromptVersion,
      );
      expect(result.turn.provenance.sourceScope.map((s) => s.id), [a, b]);
      expect(model.prompts.single, isNot(contains('999')));
      expect(model.instructionText, groundedChatInstructions);
      for (final passage in result.turn.provenance.evidence) {
        expect(passage.page, 2);
        expect(passage.heading, 'RETURN POLICY');
        expect(passage.sourceDeleted, isFalse);
        expect(passage.passageText, contains('days'));
      }
      await expectLater(
        workspace.captureEvidence(id, result.turn.id, []),
        throwsStateError,
      );
      expect(model.generalCalls, 0);
    },
  );

  runTest(
    'evidence capture rolls back mixed scope and seals only once',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final b = await source('Birch', 'Birch return deadline is 14 days.');
      final id = await chat([a]);
      final turn = await workspace.beginGroundedTurn(
        chatId: id,
        userText: 'What is the deadline?',
        model: const ModelSnapshot(identifier: 'fake', revision: '1'),
      );
      final aPassage = (await vault.knowledge.listIndexedEvidence(a)).single.id;
      final bPassage = (await vault.knowledge.listIndexedEvidence(b)).single.id;
      await expectLater(
        workspace.captureEvidence(id, turn.id, [aPassage, bPassage]),
        throwsStateError,
      );
      final unchanged = (await workspace.transcript(id)).single;
      expect(unchanged.provenance.evidence, isEmpty);
      expect(unchanged.provenance.citations, isEmpty);
      await expectLater(
        workspace.captureEvidence(id, turn.id, [aPassage, aPassage]),
        throwsArgumentError,
      );
      final sealed = await workspace.captureEvidence(id, turn.id, [aPassage]);
      expect(sealed.provenance.evidence.single.sourceId, a);
      await expectLater(
        workspace.captureEvidence(id, turn.id, []),
        throwsStateError,
      );
    },
  );

  runTest(
    'selection and title changes during retrieval affect future turns only',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final b = await source('Birch', 'Birch return deadline is 14 days.');
      final id = await chat([a]);
      embedder.gate = Completer<void>();
      final pending = engine.send(
        chatId: id,
        text: 'What is the return deadline?',
      );
      await embedder.entered.future;
      await workspace.changeScope(id, ChatMode.knowledgeBase, [b]);
      await knowledge.rename(a, 'Renamed while retrieving');
      embedder.gate!.complete();
      final first = await pending;
      expect(first.turn.provenance.sourceScope.single.id, a);
      expect(first.turn.provenance.evidence.single.sourceTitle, 'Aster');
      expect(model.prompts.first, isNot(contains('Renamed')));
      final second = await engine.send(chatId: id, text: 'And now?');
      expect(second.turn.provenance.sourceScope.single.id, b);
      expect(
        second.turn.provenance.evidence.single.passageText,
        contains('14'),
      );
      expect(
        (await workspace.transcript(id)).first.provenance.sourceScope.single.id,
        a,
      );
    },
  );

  runTest(
    'follow-ups retrieve afresh and prior assistant text remains context, not evidence',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      await vault.chats.appendTurn(
        chatId: id,
        userText: 'What is the Aster return deadline?',
        assistantText: 'Earlier mistaken answer: 999 days.',
        outcome: TurnOutcome.completed,
        mode: ChatMode.general,
        sourceScopeIds: [],
        evidencePassageIds: [],
        citationEvidenceIndexes: [],
        model: const ModelSnapshot(identifier: 'fake', revision: '1'),
      );
      await engine.send(chatId: id, text: 'How long is that?');
      await engine.send(chatId: id, text: 'Repeat it.');
      expect(embedder.queries, hasLength(2));
      expect(embedder.queries.first, contains('Aster return deadline'));
      expect(embedder.queries.first, isNot(contains('999')));
      final prompt = jsonDecode(model.prompts.first) as Map;
      expect(jsonEncode(prompt['conversation_context']), contains('999'));
      expect(jsonEncode(prompt['current_evidence']), isNot(contains('999')));
      model.answer = 'The Aster return deadline is 999 days.';
      final rejected = await engine.send(
        chatId: id,
        text: 'Use the earlier answer.',
      );
      expect(rejected.turn.outcome, TurnOutcome.insufficientEvidence);
      expect(rejected.turn.assistantText, insufficientEvidenceMessage);
      expect(model.generalCalls, 0);
    },
  );

  runTest(
    'empty evidence, model abstention, unsupported output and invented markers never fall back',
    () async {
      final empty = await source('Empty', '', empty: true);
      final emptyChat = await chat([empty]);
      final noEvidence = await engine.send(
        chatId: emptyChat,
        text: 'Any deadline?',
      );
      expect(noEvidence.turn.assistantText, insufficientEvidenceMessage);
      expect(noEvidence.turn.outcome, TurnOutcome.insufficientEvidence);
      expect(model.prompts, isEmpty);
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      for (final answer in [
        insufficientEvidenceMessage,
        'Purple elephants fly to Mars.',
        'Aster return deadline is 7 days. [1]',
      ]) {
        model.answer = answer;
        final result = await engine.send(
          chatId: id,
          text: 'What is the deadline?',
        );
        expect(result.turn.outcome, TurnOutcome.insufficientEvidence);
        expect(result.turn.assistantText, insufficientEvidenceMessage);
      }
      expect(model.generalCalls, 0);
    },
  );

  runTest(
    'budget admits only whole passages and provenance excludes rejected inputs',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final b = await source('Birch', 'Birch return deadline is 14 days.');
      final id = await chat([a, b]);
      model.window =
          810; // 50 instructions + 20 prompt + 100 passage + 640 reserve.
      final result = await engine.send(chatId: id, text: 'Return deadline?');
      expect(result.turn.outcome, TurnOutcome.completed);
      expect(result.turn.provenance.sourceScope, hasLength(2));
      expect(result.turn.provenance.evidence, hasLength(1));
      expect(result.turn.provenance.citations, hasLength(1));
      expect(
        (jsonDecode(model.prompts.single)['current_evidence'] as List),
        hasLength(1),
      );
      model.window = 809;
      final overflow = await engine.send(chatId: id, text: 'Return deadline?');
      expect(overflow.turn.failure, TurnFailure.contextOverflow);
      expect(model.prompts, hasLength(1));
    },
  );

  runTest(
    'regeneration restores original mode/scope and excludes later context',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final b = await source('Birch', 'Birch return deadline is 14 days.');
      final id = await chat([a]);
      final original = await engine.send(
        chatId: id,
        text: 'Original deadline question',
      );
      await workspace.changeScope(id, ChatMode.general, [b]);
      await engine.send(chatId: id, text: 'Later secret');
      final result = await engine.regenerate(
        chatId: id,
        turnId: original.turn.id,
      );
      expect(result.turn.provenance.mode, ChatMode.knowledgeBase);
      expect(result.turn.provenance.sourceScope.single.id, a);
      expect(model.prompts.last, isNot(contains('Later secret')));
      expect(model.prompts, hasLength(2));
      expect((await workspace.history()).single.mode, ChatMode.general);
      expect((await workspace.transcript(id)), hasLength(3));
    },
  );

  runTest(
    'deleted original sources keep citation text and block regeneration',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      final original = await engine.send(chatId: id, text: 'Deadline?');
      await knowledge.delete(a);
      final retained = (await workspace.transcript(id)).single;
      expect(retained.assistantText, original.turn.assistantText);
      expect(retained.provenance.evidence.single.sourceDeleted, isTrue);
      expect(
        await knowledge.resolveCitation(retained.provenance.evidence.single),
        isNull,
      );
      await expectLater(
        engine.regenerate(chatId: id, turnId: original.turn.id),
        throwsStateError,
      );
      expect(model.prompts, hasLength(1));
      expect(model.generalCalls, 0);
    },
  );

  runTest(
    'source invalidation between retrieval and capture fails without generation',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      model.beforeCandidateCount = () => knowledge.invalidateIndex(a);
      final result = await engine.send(chatId: id, text: 'Deadline?');
      expect(result.turn.failure, TurnFailure.sourcesUnavailable);
      expect(result.turn.provenance.evidence, isEmpty);
      expect(model.prompts, isEmpty);
    },
  );

  runTest(
    'processing sources cannot start, and query failures stay distinct',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      await knowledge.invalidateIndex(a);
      await expectLater(
        engine.send(chatId: id, text: 'Deadline?'),
        throwsStateError,
      );
      expect(await workspace.transcript(id), isEmpty);
      await vault.knowledge.setState(a, KnowledgeProcessingState.indexed);
      embedder.fail = true;
      final result = await engine.send(chatId: id, text: 'Deadline?');
      expect(result.turn.failure, TurnFailure.retrievalUnavailable);
      expect(model.prompts, isEmpty);
    },
  );

  runTest(
    'Stop during retrieval preserves scope and rejects concurrent General sends',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      final other = await workspace.newChat();
      embedder.gate = Completer<void>();
      final pending = engine.send(chatId: id, text: 'Deadline?');
      await embedder.entered.future;
      await expectLater(
        engine.send(chatId: other.id, text: 'Hello'),
        throwsStateError,
      );
      await engine.stop();
      expect((await pending).turn.outcome, TurnOutcome.stopped);
      embedder.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(model.prompts, isEmpty);
      expect(
        (await workspace.transcript(
          id,
        )).single.provenance.sourceScope.single.id,
        a,
      );
    },
  );

  runTest(
    'grounded suspension cancels a silent model and preserves captured evidence',
    () async {
      final a = await source('Aster', 'Aster return deadline is 7 days.');
      final id = await chat([a]);
      model.hold = StreamController<String>(
        onCancel: () {
          model.cancelled = true;
        },
      );
      final pending = engine.send(chatId: id, text: 'Deadline?');
      await model.started.future;
      await engine.suspend();
      final result = await pending;
      expect(result.turn.outcome, TurnOutcome.interrupted);
      expect(result.turn.provenance.evidence, hasLength(1));
      expect(model.cancelled, isTrue);
      await engine.resume();
    },
  );

  runTest(
    'schema four migration preserves sealed provenance across restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sekret-grounded-',
      );
      final path = '${directory.path}/vault.sqlite3';
      try {
        await engine.dispose();
        await knowledge.dispose();
        await workspace.dispose();
        await vault.close();
        vault = await openLocalDataVault(databasePath: path);
        await compose();
        final a = await source('Aster', 'Aster return deadline is 7 days.');
        final id = await chat([a]);
        final original = await engine.send(chatId: id, text: 'Deadline?');
        await engine.dispose();
        await knowledge.dispose();
        await workspace.dispose();
        await vault.close();
        final db = sqlite3.open(path);
        db.execute(
          'ALTER TABLE turn_provenance DROP COLUMN evidence_captured; PRAGMA user_version = 4;',
        );
        db.close();
        vault = await openLocalDataVault(databasePath: path);
        await compose();
        expect(
          (await workspace.transcript(
            id,
          )).single.provenance.evidence.single.passageText,
          contains('7 days'),
        );
        await expectLater(
          workspace.captureEvidence(id, original.turn.id, []),
          throwsStateError,
        );
        expect(
          (await engine.regenerate(
            chatId: id,
            turnId: original.turn.id,
          )).turn.outcome,
          TurnOutcome.completed,
        );
      } finally {
        await engine.dispose();
        await knowledge.dispose();
        await workspace.dispose();
        await vault.close();
        await directory.delete(recursive: true);
        vault = await openLocalDataVault(databasePath: ':memory:');
        await compose();
      }
    },
  );
}

final class QueryEmbedder implements Embedder {
  final queries = <String>[];
  final entered = Completer<void>();
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<List<double>> embed(String text) async {
    queries.add(text);
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (fail) {
      throw const EmbeddingException(
        EmbeddingFailureCode.unavailable,
        'PRIVATE',
      );
    }
    return [1, 0];
  }
}

final class GroundedModel
    implements GeneralLlmBackend, GroundedLlmBackend, ModelContextProbe {
  final prompts = <String>[];
  final started = Completer<void>();
  StreamController<String>? hold;
  bool cancelled = false;
  int generalCalls = 0;
  String? answer;
  String? instructionText;
  int window = 4096;
  Future<void> Function()? beforeAnswer;
  Future<void> Function()? beforeCandidateCount;
  @override
  Future<LlmAvailability> availability() async => const Available();
  @override
  Stream<String> generateGeneral({required String prompt}) {
    generalCalls++;
    return Stream.value('General response.');
  }

  @override
  Stream<String> generateGrounded({required String prompt}) {
    prompts.add(prompt);
    if (!started.isCompleted) started.complete();
    return hold?.stream ?? respond(prompt);
  }

  Stream<String> respond(String prompt) async* {
    await beforeAnswer?.call();
    yield answer ??
        (jsonDecode(prompt)['current_evidence'] as List)
            .map((item) => item['passage'])
            .join('\n');
  }

  @override
  Future<int> contextWindowSize() async => window;
  @override
  Future<int> countInstructionTokens(String instructions) async {
    instructionText = instructions;
    return 50;
  }

  @override
  Future<int> countPromptTokens(String prompt) async {
    final count =
        (jsonDecode(prompt)['current_evidence'] as List?)?.length ?? 0;
    if (count > 0 && beforeCandidateCount != null) {
      final callback = beforeCandidateCount!;
      beforeCandidateCount = null;
      await callback();
    }
    return 20 + count * 100;
  }
}
