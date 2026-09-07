import 'dart:async';
import 'dart:convert';

import '../knowledge/knowledge_base.dart';
import '../platform/embedder.dart';
import '../platform/llm_backend.dart';
import '../platform/token_counter.dart';
import '../question/document_question_service.dart'
    show insufficientEvidenceMessage;
import '../storage/local_data_vault.dart';
import 'chat_workspace.dart';

final class ChatTurnResult {
  const ChatTurnResult(this.turn, {required this.earlierContextSummarized});
  final TurnRecord turn;
  final bool earlierContextSummarized;
}

/// App-lifetime generation controller for both modes. General mode never calls
/// the optional Knowledge Base. No network or shared model session is used.
/// UI integration owns one instance and routes actual backgrounding to suspend.
final class ChatEngine {
  ChatEngine({
    required this._workspace,
    required this._backend,
    required this._contextProbe,
    required ModelSnapshot model,
    this.knowledgeBase,
    this.groundedBackend,
  }) : _model = ModelSnapshot(
         identifier: model.identifier,
         revision: model.revision,
         metadata: Map.unmodifiable(model.metadata),
       );

  final ChatWorkspace _workspace;
  final GeneralLlmBackend _backend;
  final ModelContextProbe _contextProbe;
  final ModelSnapshot _model;
  final KnowledgeBase? knowledgeBase;
  final GroundedLlmBackend? groundedBackend;
  _ActiveTurn? _active;
  bool _disposed = false;
  bool _suspended = false;

  bool get isGenerating => _active != null;
  Future<LlmAvailability> availability() => _backend.availability();

  /// Returns the persisted terminal turn. Streamed snapshots are observable
  /// through workspace.changes/transcript. Busy submissions are never queued.
  Future<ChatTurnResult> send({required String chatId, required String text}) =>
      _start(chatId, text);

  /// Append a new attempt using context strictly before the original turn.
  /// Neither the original answer nor subsequent turns are silently deleted.
  Future<ChatTurnResult> regenerate({
    required String chatId,
    required String turnId,
  }) => _start(chatId, '', regenerateTurnId: turnId);

  Future<ChatTurnResult> _start(
    String chatId,
    String text, {
    String? regenerateTurnId,
  }) {
    if (_disposed || _suspended || isGenerating) {
      return Future.error(
        StateError('Chat generation is not available right now.'),
      );
    }
    final active = _ActiveTurn();
    _active =
        active; // Reserve synchronously, including availability/preflight.
    return _execute(active, chatId, text, regenerateTurnId).whenComplete(() {
      _active = null;
      active.done.complete();
    });
  }

  Future<ChatTurnResult> _execute(
    _ActiveTurn active,
    String chatId,
    String text,
    String? regenerateTurnId,
  ) async {
    // Do not race this write against cancellation: always obtain its identity
    // before recording Stop, even if Stop was tapped during admission.
    final mode = regenerateTurnId == null
        ? (await _workspace.history())
              .firstWhere((chat) => chat.id == chatId)
              .mode
        : (await _workspace.transcript(
            chatId,
          )).firstWhere((turn) => turn.id == regenerateTurnId).provenance.mode;
    final grounded = mode == ChatMode.knowledgeBase;
    if (grounded && (knowledgeBase == null || groundedBackend == null)) {
      throw StateError('Knowledge Base generation is unavailable.');
    }
    final model = ModelSnapshot(
      identifier: _model.identifier,
      revision: _model.revision,
      metadata: {
        ..._model.metadata,
        'promptVersion': grounded
            ? groundedPromptVersion
            : generalPromptVersion,
      },
    );
    var turn = grounded
        ? await _workspace.beginGroundedTurn(
            chatId: chatId,
            userText: text,
            model: model,
            regenerateTurnId: regenerateTurnId,
          )
        : await _workspace.beginGeneralTurn(
            chatId: chatId,
            userText: text,
            model: model,
            regenerateTurnId: regenerateTurnId,
          );
    var outcome = TurnOutcome.completed;
    TurnFailure? failure;
    var response = '';
    var summarized = false;
    StreamIterator<String>? iterator;
    try {
      final availability = await active.wait(_backend.availability());
      if (availability is! Available) {
        throw _TurnFailure(switch (availability) {
          DeviceNotEligible() => TurnFailure.deviceNotEligible,
          AppleIntelligenceNotEnabled() =>
            TurnFailure.appleIntelligenceNotEnabled,
          _ => TurnFailure.modelNotReady,
        });
      }
      var boundary = turn.ordinal;
      if (regenerateTurnId != null) {
        final turns = await active.wait(_workspace.transcript(chatId));
        boundary = turns.firstWhere((t) => t.id == regenerateTurnId).ordinal;
      }
      final context = await active.wait(
        _workspace.context(chatId, beforeOrdinal: boundary),
      );
      summarized = context.summary != null;
      final conversation = {
        'context_summary': context.summary?.text,
        'recent_turns': [
          for (final previous in context.recentTurns)
            {
              'user': previous.userText,
              'assistant': previous.assistantText,
              'outcome': previous.outcome.name,
            },
        ],
        'current_user_message': turn.userText,
      };
      final prompt = jsonEncode(conversation);
      final size = await active.wait(_contextProbe.contextWindowSize());
      final instructions = await active.wait(
        _contextProbe.countInstructionTokens(
          grounded ? groundedChatInstructions : generalInstructions,
        ),
      );
      String groundedPrompt(List<StoredEvidencePassage> passages) =>
          jsonEncode({
            'conversation_context': {
              'context_summary': context.summary?.text,
              'recent_turns': conversation['recent_turns'],
            },
            'current_user_message': turn.userText,
            'current_evidence': [
              for (final passage in passages)
                {
                  'source_id': passage.knowledgeItemId,
                  'source_title': turn.provenance.sourceScope
                      .firstWhere(
                        (source) => source.id == passage.knowledgeItemId,
                      )
                      .title,
                  'page': passage.page,
                  'section': passage.heading,
                  'passage': passage.text,
                },
            ],
          });
      final tokens = await active.wait(
        _contextProbe.countPromptTokens(grounded ? groundedPrompt([]) : prompt),
      );
      if (size <= 0 || instructions <= 0 || tokens <= 0) {
        throw const _TurnFailure(TurnFailure.streamFailure);
      }
      // Native output cap is 512 tokens. Reserve a further 128 for framing.
      // Never silently truncate the current message or partial history sections.
      if (instructions + tokens + 512 + 128 > size) {
        throw const _TurnFailure(TurnFailure.contextOverflow);
      }
      var generationPrompt = prompt;
      if (grounded) {
        // Previous user questions supply referents for follow-ups, not facts.
        // Earlier assistant responses never enter the evidence set.
        final query = [
          ...context.recentTurns
              .skip(
                context.recentTurns.length > 2
                    ? context.recentTurns.length - 2
                    : 0,
              )
              .map((prior) => prior.userText),
          turn.userText,
        ].join('\n');
        final candidates = await active.wait(
          knowledgeBase!.retrieveAcross(
            sourceIds: turn.provenance.sourceScope
                .map((source) => source.id)
                .toList(),
            question: query,
          ),
        );
        final admitted = <StoredEvidencePassage>[];
        for (final candidate in candidates) {
          final count = await active.wait(
            _contextProbe.countPromptTokens(
              groundedPrompt([...admitted, candidate]),
            ),
          );
          if (count <= 0) throw const _TurnFailure(TurnFailure.streamFailure);
          if (instructions + count + 512 + 128 <= size) admitted.add(candidate);
          if (admitted.length == 4) break;
        }
        if (candidates.isNotEmpty && admitted.isEmpty) {
          throw const _TurnFailure(TurnFailure.contextOverflow);
        }
        generationPrompt = groundedPrompt(admitted);
        // Do not abandon a queued persistence operation on Stop; its one-time
        // write must settle before the terminal outcome is recorded.
        try {
          turn = await _workspace.captureEvidence(
            chatId,
            turn.id,
            admitted.map((passage) => passage.id).toList(),
          );
        } on StateError {
          throw const _TurnFailure(TurnFailure.sourcesUnavailable);
        } on VaultWriteException catch (error) {
          if (error.cause is StateError) {
            throw const _TurnFailure(TurnFailure.sourcesUnavailable);
          }
          rethrow;
        }
        active.check();
        if (admitted.isEmpty) throw const _InsufficientEvidence();
      }
      active.check();
      iterator = StreamIterator(
        grounded
            ? groundedBackend!.generateGrounded(prompt: generationPrompt)
            : _backend.generateGeneral(prompt: generationPrompt),
      );
      var lastSnapshot = '';
      while (await active.wait(iterator.moveNext())) {
        active.check();
        lastSnapshot = iterator.current;
        if (!grounded ||
            _hasEvidenceSupport(lastSnapshot, turn.provenance.evidence)) {
          response = lastSnapshot;
          await _workspace.saveResponse(turn.id, response);
        }
      }
      active.check();
      if (lastSnapshot.trim().isEmpty) {
        throw const _TurnFailure(TurnFailure.streamFailure);
      }
      if (grounded &&
          lastSnapshot.trim().isNotEmpty &&
          (lastSnapshot.trim() == insufficientEvidenceMessage ||
              !_hasEvidenceSupport(lastSnapshot, turn.provenance.evidence))) {
        throw const _InsufficientEvidence();
      }
      if (response.trim().isEmpty) {
        throw const _TurnFailure(TurnFailure.streamFailure);
      }
    } on _InsufficientEvidence {
      outcome = TurnOutcome.insufficientEvidence;
      response = insufficientEvidenceMessage;
    } on KnowledgeScopeUnavailable {
      outcome = TurnOutcome.failed;
      failure = TurnFailure.sourcesUnavailable;
    } on EmbeddingException {
      outcome = TurnOutcome.failed;
      failure = TurnFailure.retrievalUnavailable;
    } on _TurnCancelled catch (cancelled) {
      outcome = cancelled.outcome;
    } on _TurnFailure catch (error) {
      outcome = TurnOutcome.failed;
      failure = error.failure;
    } on LlmException catch (error) {
      outcome = error.code == LlmFailureCode.interrupted
          ? TurnOutcome.interrupted
          : TurnOutcome.failed;
      failure = switch (error.code) {
        LlmFailureCode.unavailable => TurnFailure.unavailable,
        LlmFailureCode.contextOverflow => TurnFailure.contextOverflow,
        LlmFailureCode.guardrailViolation => TurnFailure.guardrailViolation,
        LlmFailureCode.streamFailure => TurnFailure.streamFailure,
        LlmFailureCode.interrupted => null,
      };
    } on Object {
      outcome = TurnOutcome.failed;
      failure = TurnFailure.streamFailure;
    } finally {
      await iterator?.cancel();
    }
    // Stop/backgrounding wins even if it arrived during the last storage write
    // or while native cancellation was being acknowledged.
    if (active.cancelled != null) {
      outcome = active.cancelled!;
      failure = null;
    }
    await _workspace.saveResponse(
      turn.id,
      response,
      outcome: outcome,
      failure: failure,
    );
    final saved = (await _workspace.transcript(
      chatId,
    )).firstWhere((t) => t.id == turn.id);
    return ChatTurnResult(saved, earlierContextSummarized: summarized);
  }

  Future<void> stop() => _cancel(TurnOutcome.stopped);

  Future<void> _cancel(TurnOutcome outcome) async {
    final active = _active;
    if (active == null) return;
    active.cancel(outcome);
    await active.done.future;
  }

  Future<void> suspend() async {
    _suspended = true;
    await _cancel(TurnOutcome.interrupted);
    await _workspace.suspend();
  }

  Future<void> resume() async {
    if (_disposed) throw StateError('Chat generation is disposed.');
    if (isGenerating) throw StateError('Stop generation before resuming.');
    await _workspace.resume();
    _suspended = false;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _cancel(TurnOutcome.interrupted);
  }
}

final class _ActiveTurn {
  final done = Completer<void>();
  final signal = Completer<void>();
  TurnOutcome? cancelled;
  void cancel(TurnOutcome outcome) {
    if (cancelled != null) return;
    cancelled = outcome;
    signal.complete();
  }

  void check() {
    if (cancelled != null) throw _TurnCancelled(cancelled!);
  }

  Future<T> wait<T>(Future<T> work) async {
    // Always subscribe to work, even after cancellation, so a late platform
    // error cannot escape as an unhandled asynchronous exception.
    final value = await Future.any([
      work,
      signal.future.then<T>((_) => throw _TurnCancelled(cancelled!)),
    ]);
    check();
    return value;
  }
}

final class _TurnCancelled implements Exception {
  const _TurnCancelled(this.outcome);
  final TurnOutcome outcome;
}

final class _TurnFailure implements Exception {
  const _TurnFailure(this.failure);
  final TurnFailure failure;
}

final class _InsufficientEvidence implements Exception {
  const _InsufficientEvidence();
}

/// Conservative evidence-presence screen, not a semantic entailment proof.
/// Citations are source cards; this heuristic NEVER creates inline attribution.
bool _hasEvidenceSupport(String answer, List<TurnEvidenceSnapshot> evidence) {
  if (answer.trim().isEmpty || answer.trim() == insufficientEvidenceMessage) {
    return false;
  }
  // Model-authored citation markers have no independently established meaning.
  if (RegExp(r'\[\s*\d+(?:\s*,\s*\d+)*\s*\]').hasMatch(answer)) return false;
  final source = evidence
      .map(
        (passage) =>
            '${passage.sourceTitle}\n${passage.heading}\n${passage.passageText}',
      )
      .join('\n')
      .toLowerCase();
  final numbers = RegExp(r'\d+(?:[.,]\d+)*');
  final sourceNumbers = numbers
      .allMatches(source)
      .map((match) => match.group(0))
      .toSet();
  if (numbers
      .allMatches(answer)
      .any((match) => !sourceNumbers.contains(match.group(0)))) {
    return false;
  }
  const ignored = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'by',
    'for',
    'from',
    'in',
    'is',
    'it',
    'of',
    'on',
    'or',
    'that',
    'the',
    'this',
    'to',
    'was',
    'with',
    'answer',
    'document',
    'source',
    'sources',
  };
  final terms = RegExp(r'[\p{L}\p{N}]+', unicode: true)
      .allMatches(answer.toLowerCase())
      .map((match) => match.group(0)!)
      .where((term) => !ignored.contains(term))
      .toSet();
  final sourceTerms = RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(source).map((match) => match.group(0)).toSet();
  return terms.isNotEmpty &&
      terms.where(sourceTerms.contains).length / terms.length >= 0.5;
}
