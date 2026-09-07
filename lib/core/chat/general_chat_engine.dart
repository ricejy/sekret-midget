import 'dart:async';
import 'dart:convert';

import '../platform/llm_backend.dart';
import '../platform/token_counter.dart';
import '../storage/local_data_vault.dart';
import 'chat_workspace.dart';

final class GeneralTurnResult {
  const GeneralTurnResult(this.turn, {required this.earlierContextSummarized});
  final TurnRecord turn;
  final bool earlierContextSummarized;
}

/// App-lifetime generation controller for the Chat Workspace. No knowledge
/// repository, retriever, network client, or shared model session is accessible.
/// UI integration owns one instance and routes actual backgrounding to suspend.
final class GeneralChatEngine {
  GeneralChatEngine({
    required this._workspace,
    required this._backend,
    required this._contextProbe,
    required ModelSnapshot model,
  }) : _model = ModelSnapshot(
         identifier: model.identifier,
         revision: model.revision,
         metadata: {...model.metadata, 'promptVersion': generalPromptVersion},
       );

  final ChatWorkspace _workspace;
  final GeneralLlmBackend _backend;
  final ModelContextProbe _contextProbe;
  final ModelSnapshot _model;
  _ActiveGeneralTurn? _active;
  bool _disposed = false;
  bool _suspended = false;

  bool get isGenerating => _active != null;
  Future<LlmAvailability> availability() => _backend.availability();

  /// Returns the persisted terminal turn. Streamed snapshots are observable
  /// through workspace.changes/transcript. Busy submissions are never queued.
  Future<GeneralTurnResult> send({
    required String chatId,
    required String text,
  }) => _start(chatId, text);

  /// Append a new attempt using context strictly before the original turn.
  /// Neither the original answer nor subsequent turns are silently deleted.
  Future<GeneralTurnResult> regenerate({
    required String chatId,
    required String turnId,
  }) => _start(chatId, '', regenerateTurnId: turnId);

  Future<GeneralTurnResult> _start(
    String chatId,
    String text, {
    String? regenerateTurnId,
  }) {
    if (_disposed || _suspended || isGenerating) {
      return Future.error(
        StateError('Chat generation is not available right now.'),
      );
    }
    final active = _ActiveGeneralTurn();
    _active =
        active; // Reserve synchronously, including availability/preflight.
    return _execute(active, chatId, text, regenerateTurnId).whenComplete(() {
      _active = null;
      active.done.complete();
    });
  }

  Future<GeneralTurnResult> _execute(
    _ActiveGeneralTurn active,
    String chatId,
    String text,
    String? regenerateTurnId,
  ) async {
    // Do not race this write against cancellation: always obtain its identity
    // before recording Stop, even if Stop was tapped during admission.
    final turn = await _workspace.beginGeneralTurn(
      chatId: chatId,
      userText: text,
      model: _model,
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
        throw _GeneralFailure(switch (availability) {
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
      final prompt = jsonEncode({
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
      });
      final size = await active.wait(_contextProbe.contextWindowSize());
      final instructions = await active.wait(
        _contextProbe.countInstructionTokens(generalInstructions),
      );
      final tokens = await active.wait(_contextProbe.countPromptTokens(prompt));
      if (size <= 0 || instructions <= 0 || tokens <= 0) {
        throw const _GeneralFailure(TurnFailure.streamFailure);
      }
      // Native output cap is 512 tokens. Reserve a further 128 for framing.
      // Never silently truncate the current message or partial history sections.
      if (instructions + tokens + 512 + 128 > size) {
        throw const _GeneralFailure(TurnFailure.contextOverflow);
      }
      active.check();
      iterator = StreamIterator(_backend.generateGeneral(prompt: prompt));
      while (await active.wait(iterator.moveNext())) {
        active.check();
        response = iterator.current;
        await _workspace.saveResponse(turn.id, response);
      }
      active.check();
      if (response.trim().isEmpty) {
        throw const _GeneralFailure(TurnFailure.streamFailure);
      }
    } on _GeneralCancelled catch (cancelled) {
      outcome = cancelled.outcome;
    } on _GeneralFailure catch (error) {
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
    return GeneralTurnResult(saved, earlierContextSummarized: summarized);
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

final class _ActiveGeneralTurn {
  final done = Completer<void>();
  final signal = Completer<void>();
  TurnOutcome? cancelled;
  void cancel(TurnOutcome outcome) {
    if (cancelled != null) return;
    cancelled = outcome;
    signal.complete();
  }

  void check() {
    if (cancelled != null) throw _GeneralCancelled(cancelled!);
  }

  Future<T> wait<T>(Future<T> work) async {
    // Always subscribe to work, even after cancellation, so a late platform
    // error cannot escape as an unhandled asynchronous exception.
    final value = await Future.any([
      work,
      signal.future.then<T>((_) => throw _GeneralCancelled(cancelled!)),
    ]);
    check();
    return value;
  }
}

final class _GeneralCancelled implements Exception {
  const _GeneralCancelled(this.outcome);
  final TurnOutcome outcome;
}

final class _GeneralFailure implements Exception {
  const _GeneralFailure(this.failure);
  final TurnFailure failure;
}
