import 'dart:async';
import 'dart:convert';

import '../storage/local_data_vault.dart';

/// The model receives this context; the visible transcript always stays intact.
final class ChatContext {
  ChatContext(this.summary, List<TurnRecord> recentTurns)
    : recentTurns = List.unmodifiable(recentTurns);

  final ContextSummaryRecord? summary;
  final List<TurnRecord> recentTurns;
}

final class RetentionPreview {
  RetentionPreview._(this.policy, this._candidates, this._owner);
  final RetentionPolicy policy;
  final List<ChatRecord> _candidates;
  final Object _owner;
  int get affectedChats => _candidates.length;
  bool _applied = false;
}

/// Owns chat lifecycle. One instance should live for the app's lifetime.
/// Call [resume] on launch/resume and [suspend] before backgrounding.
/// The caller owns the vault and closes it after disposing this workspace.
final class ChatWorkspace {
  ChatWorkspace._(this._vault, this._clock, this.undoWindow);

  static Future<ChatWorkspace> open(
    LocalDataVault vault, {
    DateTime Function()? clock,
    Duration undoWindow = const Duration(seconds: 5),
  }) async {
    if (undoWindow <= Duration.zero) {
      throw ArgumentError('Undo window must be positive.');
    }
    final workspace = ChatWorkspace._(vault, clock ?? DateTime.now, undoWindow);
    await workspace.resume();
    return workspace;
  }

  final LocalDataVault _vault;
  final DateTime Function() _clock;
  final Duration undoWindow;
  final _changes = StreamController<void>.broadcast();
  Future<void> _tail = Future.value();
  Timer? _deletionTimer;
  bool _disposed = false;
  String? _currentChatId;

  String? get currentChatId => _currentChatId;
  Stream<void> get changes => _changes.stream;

  Future<T> _run<T>(Future<T> Function() action, {bool notify = true}) {
    if (_disposed) {
      return Future.error(StateError('Chat workspace is disposed.'));
    }
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {
      if (notify && !_disposed) _changes.add(null);
    }, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<ChatRecord> newChat() => _run(() async {
    final chat = await _vault.chats.createChat();
    await _vault.chats.selectChat(chat.id);
    _currentChatId = chat.id;
    return chat;
  });

  Future<ChatRecord> openChat(String id) => _run(() async {
    final chat = await _findChat(id);
    await _vault.chats.selectChat(id);
    _currentChatId = id;
    return chat;
  });

  Future<ChatRecord> _findChat(String id) async {
    final chats = await _vault.chats.listChats();
    return chats.firstWhere(
      (chat) => chat.id == id,
      orElse: () => throw StateError('Chat is unavailable.'),
    );
  }

  Future<List<ChatRecord>> history({String query = ''}) => _run(() async {
    final chats = await _vault.chats.listChats();
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return List.unmodifiable(chats);
    final matches = <ChatRecord>[];
    for (final chat in chats) {
      if (chat.title.toLowerCase().contains(needle) ||
          (await _vault.chats.listTurns(chat.id)).any(
            (turn) =>
                turn.userText.toLowerCase().contains(needle) ||
                turn.assistantText.toLowerCase().contains(needle),
          )) {
        matches.add(chat);
      }
    }
    return List.unmodifiable(matches);
  }, notify: false);

  Future<List<TurnRecord>> transcript(String chatId) =>
      _run(() => _vault.chats.listTurns(chatId), notify: false);

  Future<void> rename(String chatId, String title) =>
      _run(() => _vault.chats.renameChat(chatId, title));

  Future<void> changeScope(
    String chatId,
    ChatMode mode,
    List<String> sourceIds,
  ) {
    final sources = List<String>.of(sourceIds);
    return _run(
      () => _vault.chats.updateScope(
        chatId: chatId,
        mode: mode,
        selectedSourceIds: sources,
      ),
    );
  }

  /// Captures mode and sources before the generation adapter starts.
  Future<TurnRecord> beginTurn({
    required String chatId,
    required String userText,
    required ModelSnapshot model,
    List<int> evidencePassageIds = const [],
    List<int> citationEvidenceIndexes = const [],
  }) {
    final evidence = List<int>.of(evidencePassageIds);
    final citations = List<int>.of(citationEvidenceIndexes);
    return _run(() async {
      if (userText.trim().isEmpty) throw ArgumentError('Enter a message.');
      final chat = await _findChat(chatId);
      final sources = chat.mode == ChatMode.general
          ? <String>[]
          : chat.selectedSourceIds;
      if (chat.mode == ChatMode.general &&
          (evidence.isNotEmpty || citations.isNotEmpty)) {
        throw StateError('General mode cannot use knowledge evidence.');
      }
      if (chat.mode == ChatMode.knowledgeBase) {
        if (sources.isEmpty) throw StateError('Select a source.');
        for (final id in sources) {
          if ((await _vault.knowledge.get(id)).processingState !=
              KnowledgeProcessingState.indexed) {
            throw StateError('Selected sources are not indexed.');
          }
        }
      }
      return _vault.chats.appendTurn(
        chatId: chatId,
        userText: userText.trim(),
        assistantText: '',
        outcome: TurnOutcome.generating,
        mode: chat.mode,
        sourceScopeIds: sources,
        evidencePassageIds: evidence,
        citationEvidenceIndexes: citations,
        model: model,
      );
    });
  }

  /// Persist each streamed snapshot so suspension can preserve partial text.
  Future<void> saveResponse(
    String turnId,
    String text, {
    TurnOutcome outcome = TurnOutcome.generating,
    TurnFailure? failure,
  }) => _run(
    () => _vault.chats.finishTurn(turnId, text, outcome, failure: failure),
  );

  /// Atomic General-only admission. Regeneration retains the original turn and
  /// appends a new attempt without changing the chat's current mode/sources.
  Future<TurnRecord> beginGeneralTurn({
    required String chatId,
    required String userText,
    required ModelSnapshot model,
    String? regenerateTurnId,
  }) => _run(() async {
    final chat = await _findChat(chatId);
    var text = userText.trim();
    if (regenerateTurnId != null) {
      final original = (await _vault.chats.listTurns(
        chatId,
      )).firstWhere((turn) => turn.id == regenerateTurnId);
      if (original.provenance.mode != ChatMode.general ||
          original.outcome == TurnOutcome.generating) {
        throw StateError(
          'Only terminal General turns can be regenerated here.',
        );
      }
      text = original.userText;
    } else if (chat.mode != ChatMode.general) {
      throw StateError('Choose General mode before sending.');
    }
    if (text.isEmpty) throw ArgumentError('Enter a message.');
    return _vault.chats.appendTurn(
      chatId: chatId,
      userText: text,
      assistantText: '',
      outcome: TurnOutcome.generating,
      mode: ChatMode.general,
      sourceScopeIds: const [],
      evidencePassageIds: const [],
      citationEvidenceIndexes: const [],
      model: model,
    );
  });

  Future<void> deleteFromTurn(String chatId, String turnId) =>
      _run(() => _vault.chats.deleteFromTurn(chatId, turnId));

  Future<TurnRecord> beginGroundedTurn({
    required String chatId,
    required String userText,
    required ModelSnapshot model,
    String? regenerateTurnId,
  }) => _run(() async {
    final chat = await _findChat(chatId);
    var text = userText.trim();
    var sources = chat.selectedSourceIds;
    if (regenerateTurnId != null) {
      final original = (await _vault.chats.listTurns(
        chatId,
      )).firstWhere((turn) => turn.id == regenerateTurnId);
      if (original.provenance.mode != ChatMode.knowledgeBase ||
          original.outcome == TurnOutcome.generating) {
        throw StateError(
          'Only terminal grounded turns can be regenerated here.',
        );
      }
      sources = original.provenance.sourceScope
          .map((source) => source.id)
          .toList();
      text = original.userText;
    } else if (chat.mode != ChatMode.knowledgeBase) {
      throw StateError('Choose Knowledge Base mode before sending.');
    }
    if (text.isEmpty) throw ArgumentError('Enter a message.');
    if (sources.isEmpty) {
      throw StateError('Select at least one indexed source.');
    }
    for (final id in sources) {
      if ((await _vault.knowledge.get(id)).processingState !=
          KnowledgeProcessingState.indexed) {
        throw StateError(
          'All original sources must be indexed before sending.',
        );
      }
    }
    return _vault.chats.appendTurn(
      chatId: chatId,
      userText: text,
      assistantText: '',
      outcome: TurnOutcome.generating,
      mode: ChatMode.knowledgeBase,
      sourceScopeIds: sources,
      evidencePassageIds: const [],
      citationEvidenceIndexes: const [],
      model: model,
      deferEvidence: true,
    );
  });

  Future<TurnRecord> captureEvidence(
    String chatId,
    String turnId,
    List<int> passageIds,
  ) {
    final ids = List<int>.of(passageIds);
    return _run(() async {
      final turn = (await _vault.chats.listTurns(
        chatId,
      )).firstWhere((turn) => turn.id == turnId);
      await _vault.chats.captureEvidence(turn.id, ids);
      return (await _vault.chats.listTurns(
        chatId,
      )).firstWhere((turn) => turn.id == turnId);
    });
  }

  Future<void> deleteChat(String chatId) => _run(() async {
    await _vault.chats.stageDeletion(chatId, _clock().toUtc().add(undoWindow));
    if (_currentChatId == chatId) {
      _currentChatId = null;
      await _vault.chats.selectChat(null);
    }
    await _scheduleDeletion();
  });

  Future<bool> undoDelete(String chatId) => _run(() async {
    final restored = await _vault.chats.undoDeletion(chatId);
    await _vault.chats.reap();
    await _scheduleDeletion();
    return restored;
  });

  Future<RetentionPreview> previewRetention(RetentionPolicy policy) => _run(
    () async => RetentionPreview._(
      policy,
      List.unmodifiable(await _vault.chats.retentionCandidates(policy)),
      this,
    ),
    notify: false,
  );

  /// Call only after the user accepts the displayed preview.
  Future<void> confirmRetention(RetentionPreview preview) => _run(() async {
    if (!identical(preview._owner, this) || preview._applied) {
      throw StateError('Retention preview is invalid or already applied.');
    }
    await _vault.chats.applyRetention(preview.policy, preview._candidates);
    preview._applied = true;
    await _restoreCurrentChat();
  });

  Future<void> resume() => _run(() async {
    await _vault.chats.recoverInterruptedTurns();
    await _vault.chats.reap();
    await _restoreCurrentChat();
    await _scheduleDeletion();
  });

  Future<void> suspend() => _run(() async {
    _deletionTimer?.cancel();
    await _vault.chats.recoverInterruptedTurns();
  });

  Future<void> _restoreCurrentChat() async {
    _currentChatId = await _vault.chats.currentChatId();
    final chats = await _vault.chats.listChats();
    if (!chats.any((chat) => chat.id == _currentChatId)) {
      _currentChatId = chats.isEmpty ? null : chats.first.id;
      await _vault.chats.selectChat(_currentChatId);
    }
  }

  Future<void> _scheduleDeletion() async {
    _deletionTimer?.cancel();
    final deadline = await _vault.chats.nextDeletionDeadline();
    if (deadline == null || _disposed) return;
    final remaining = deadline.difference(_clock().toUtc());
    _deletionTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        unawaited(
          _run(() async {
            await _vault.chats.reap();
            await _restoreCurrentChat();
            await _scheduleDeletion();
          }).catchError((Object error, StackTrace stack) {
            if (!_disposed) _changes.addError(error, stack);
          }),
        );
      },
    );
  }

  /// A deterministic, bounded extractive summary; no second model call or
  /// cross-chat state. Labels preserve the distinction between user/assistant.
  /// This context remains conversation data, never knowledge-base evidence.
  Future<ChatContext> context(
    String chatId, {
    int? beforeOrdinal,
  }) => _run(() async {
    final turns = (await _vault.chats.listTurns(chatId))
        .where((turn) => beforeOrdinal == null || turn.ordinal < beforeOrdinal)
        .toList();
    const recentCount = 4;
    if (turns.length <= recentCount) return ChatContext(null, turns);
    final older = turns.sublist(0, turns.length - recentCount);
    final through = older.last.ordinal;
    var summary = await _vault.chats.getContextSummary(chatId);
    if (summary == null || summary.summarizedThroughOrdinal != through) {
      // Retain a bounded window of older excerpts, with explicit omissions.
      final included = older.skip(older.length > 8 ? older.length - 8 : 0);
      String excerpt(String text) {
        final runes = text.runes;
        return runes.length <= 80
            ? text
            : '${String.fromCharCodes(runes.take(80))}…';
      }

      final text = jsonEncode({
        'kind':
            'Earlier conversation excerpts; omitted text remains in history',
        'turns': [
          for (final turn in included)
            {
              'turn': turn.ordinal,
              'user': excerpt(turn.userText),
              'assistant': excerpt(turn.assistantText),
              'outcome': turn.outcome.name,
            },
        ],
      });
      await _vault.chats.saveContextSummary(
        chatId: chatId,
        summarizedThroughOrdinal: through,
        text: text,
      );
      summary = await _vault.chats.getContextSummary(chatId);
    }
    return ChatContext(summary, turns.sublist(turns.length - recentCount));
  }, notify: false);

  Future<void> dispose() async {
    _disposed = true;
    _deletionTimer?.cancel();
    await _tail;
    await _changes.close();
  }
}
