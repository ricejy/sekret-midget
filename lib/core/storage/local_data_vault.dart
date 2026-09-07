import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

enum ChatMode { general, knowledgeBase }

enum TurnOutcome {
  generating,
  completed,
  stopped,
  interrupted,
  failed,
  insufficientEvidence,
}

enum TurnFailure {
  deviceNotEligible,
  appleIntelligenceNotEnabled,
  modelNotReady,
  unavailable,
  contextOverflow,
  guardrailViolation,
  streamFailure,
}

enum RetentionPolicy { manual, thirtyDays, ninetyDays }

enum AppLockDelay { immediate, oneMinute, fifteenMinutes }

enum KnowledgeSourceType { pastedText, pdf, photo }

enum KnowledgeProcessingState {
  processing,
  paused,
  indexed,
  failed,
  needsReindexing,
}

const localDataVaultSchemaVersion = 3;

final class VaultWriteException implements Exception {
  const VaultWriteException(this.cause);

  final Object cause;

  @override
  String toString() => 'The local data operation could not be completed.';
}

sealed class VaultSchemaException implements Exception {
  const VaultSchemaException();
}

final class UnsupportedVaultSchemaException extends VaultSchemaException {
  const UnsupportedVaultSchemaException({
    required this.foundVersion,
    required this.supportedVersion,
  });

  final int foundVersion;
  final int supportedVersion;

  @override
  String toString() =>
      'Vault schema $foundVersion is newer than supported schema '
      '$supportedVersion.';
}

final class UnrecognizedVaultSchemaException extends VaultSchemaException {
  const UnrecognizedVaultSchemaException(this.existingTables);

  final List<String> existingTables;

  @override
  String toString() =>
      'The database has no v2 schema version but contains existing tables.';
}

final class InvalidVaultSchemaException extends VaultSchemaException {
  const InvalidVaultSchemaException(this.missingTables);

  final List<String> missingTables;

  @override
  String toString() => 'The v2 vault is missing required tables.';
}

final class ChatRecord {
  const ChatRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.mode,
    required this.selectedSourceIds,
    this.revision = 0,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ChatMode mode;
  final List<String> selectedSourceIds;
  final int revision;
}

final class ProcessingCheckpoint {
  const ProcessingCheckpoint({
    required this.stage,
    required this.completedUnits,
    required this.totalUnits,
    required this.artifact,
    required this.updatedAt,
  });

  final String stage;
  final int completedUnits;
  final int totalUnits;
  final Uint8List artifact;
  final DateTime updatedAt;
}

final class KnowledgeItemRecord {
  const KnowledgeItemRecord({
    required this.id,
    required this.title,
    required this.sourceType,
    required this.sourceName,
    required this.pageCount,
    required this.fingerprint,
    required this.processingState,
    required this.createdAt,
    required this.updatedAt,
    required this.indexedAt,
    required this.checkpoint,
  });

  final String id;
  final String title;
  final KnowledgeSourceType sourceType;
  final String? sourceName;
  final int pageCount;
  final String fingerprint;
  final KnowledgeProcessingState processingState;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? indexedAt;
  final ProcessingCheckpoint? checkpoint;
}

final class EvidencePassageDraft {
  const EvidencePassageDraft({
    required this.ordinal,
    required this.text,
    required this.heading,
    required this.page,
    required this.tokenCount,
    required this.vector,
    required this.vectorScale,
  });

  final int ordinal;
  final String text;
  final String heading;
  final int? page;
  final int tokenCount;
  final Uint8List vector;
  final double vectorScale;
}

final class StoredEvidencePassage {
  const StoredEvidencePassage({
    required this.id,
    required this.knowledgeItemId,
    required this.ordinal,
    required this.text,
    required this.heading,
    required this.page,
    required this.tokenCount,
  });

  final int id;
  final String knowledgeItemId;
  final int ordinal;
  final String text;
  final String heading;
  final int? page;
  final int tokenCount;
}

final class ModelSnapshot {
  const ModelSnapshot({
    required this.identifier,
    required this.revision,
    this.metadata = const {},
  });

  final String identifier;
  final String revision;
  final Map<String, Object?> metadata;
}

final class TurnSourceSnapshot {
  const TurnSourceSnapshot({
    required this.id,
    required this.title,
    required this.sourceDeleted,
  });

  final String id;
  final String title;
  final bool sourceDeleted;
}

final class TurnEvidenceSnapshot {
  const TurnEvidenceSnapshot({
    required this.id,
    required this.sourceId,
    required this.sourceTitle,
    required this.passageText,
    required this.heading,
    required this.page,
    required this.rank,
    required this.sourceDeleted,
  });

  final int id;
  final String sourceId;
  final String sourceTitle;
  final String passageText;
  final String heading;
  final int? page;
  final int rank;
  final bool sourceDeleted;
}

final class TurnCitationSnapshot {
  const TurnCitationSnapshot({
    required this.id,
    required this.evidenceId,
    required this.displayOrder,
  });

  final int id;
  final int evidenceId;
  final int displayOrder;
}

final class TurnProvenance {
  const TurnProvenance({
    required this.mode,
    required this.sourceScope,
    required this.evidence,
    required this.citations,
    required this.model,
  });

  final ChatMode mode;
  final List<TurnSourceSnapshot> sourceScope;
  final List<TurnEvidenceSnapshot> evidence;
  final List<TurnCitationSnapshot> citations;
  final ModelSnapshot model;
}

final class TurnRecord {
  const TurnRecord({
    required this.id,
    required this.chatId,
    required this.ordinal,
    required this.userText,
    required this.assistantText,
    required this.outcome,
    required this.createdAt,
    required this.provenance,
    this.failure,
  });

  final String id;
  final String chatId;
  final int ordinal;
  final String userText;
  final String assistantText;
  final TurnOutcome outcome;
  final DateTime createdAt;
  final TurnProvenance provenance;
  final TurnFailure? failure;

  String get answerLabel => provenance.mode == ChatMode.general
      ? 'General answer'
      : 'Based on selected sources';
}

final class ContextSummaryRecord {
  const ContextSummaryRecord({
    required this.chatId,
    required this.summarizedThroughOrdinal,
    required this.text,
    required this.updatedAt,
  });

  final String chatId;
  final int summarizedThroughOrdinal;
  final String text;
  final DateTime updatedAt;
}

final class VaultSettingsRecord {
  const VaultSettingsRecord({
    required this.retentionPolicy,
    required this.biometricLockEnabled,
    required this.lockDelay,
  });

  final RetentionPolicy retentionPolicy;
  final bool biometricLockEnabled;
  final AppLockDelay lockDelay;
}

final class StorageUsage {
  const StorageUsage({
    required this.chatBytes,
    required this.knowledgeSourceBytes,
    required this.knowledgeIndexBytes,
  });

  const StorageUsage.zero()
    : chatBytes = 0,
      knowledgeSourceBytes = 0,
      knowledgeIndexBytes = 0;

  final int chatBytes;
  final int knowledgeSourceBytes;
  final int knowledgeIndexBytes;

  @override
  bool operator ==(Object other) =>
      other is StorageUsage &&
      other.chatBytes == chatBytes &&
      other.knowledgeSourceBytes == knowledgeSourceBytes &&
      other.knowledgeIndexBytes == knowledgeIndexBytes;

  @override
  int get hashCode =>
      Object.hash(chatBytes, knowledgeSourceBytes, knowledgeIndexBytes);
}

abstract interface class VaultChats {
  Future<String?> currentChatId();
  Future<void> selectChat(String? id);
  Future<void> renameChat(String chatId, String title);
  Future<void> deleteFromTurn(String chatId, String turnId);
  Future<void> stageDeletion(String chatId, DateTime deadline);
  Future<bool> undoDeletion(String chatId);
  Future<void> reap();
  Future<DateTime?> nextDeletionDeadline();
  Future<List<ChatRecord>> retentionCandidates(RetentionPolicy policy);
  Future<void> applyRetention(
    RetentionPolicy policy,
    List<ChatRecord> candidates,
  );
  Future<void> finishTurn(
    String turnId,
    String text,
    TurnOutcome outcome, {
    TurnFailure? failure,
  });
  Future<void> recoverInterruptedTurns();
  Future<ChatRecord> createChat();

  Future<List<ChatRecord>> listChats();

  Future<void> updateScope({
    required String chatId,
    required ChatMode mode,
    required List<String> selectedSourceIds,
  });

  Future<TurnRecord> appendTurn({
    required String chatId,
    required String userText,
    required String assistantText,
    required TurnOutcome outcome,
    required ChatMode mode,
    required List<String> sourceScopeIds,
    required List<int> evidencePassageIds,
    required List<int> citationEvidenceIndexes,
    required ModelSnapshot model,
  });

  Future<List<TurnRecord>> listTurns(String chatId);

  Future<void> saveContextSummary({
    required String chatId,
    required int summarizedThroughOrdinal,
    required String text,
  });

  Future<ContextSummaryRecord?> getContextSummary(String chatId);
}

abstract interface class VaultKnowledge {
  Future<KnowledgeItemRecord> beginProcessing({
    required String title,
    required KnowledgeSourceType sourceType,
    required Uint8List sourceBytes,
    String? sourceName,
    required String fingerprint,
  });

  Future<void> saveCheckpoint({
    required String knowledgeItemId,
    required String stage,
    required int completedUnits,
    required int totalUnits,
    required Uint8List artifact,
  });

  Future<void> completeIndex({
    required String knowledgeItemId,
    required String extractedText,
    int pageCount = 0,
    required List<EvidencePassageDraft> passages,
  });

  Future<KnowledgeItemRecord> get(String knowledgeItemId);

  Future<List<KnowledgeItemRecord>> list();

  Future<void> delete(String knowledgeItemId);

  Future<List<StoredEvidencePassage>> listIndexedEvidence(
    String knowledgeItemId,
  );
}

abstract interface class VaultSettings {
  Future<VaultSettingsRecord> get();

  Future<void> update({
    required RetentionPolicy retentionPolicy,
    required bool biometricLockEnabled,
    required AppLockDelay lockDelay,
  });
}

abstract interface class LocalDataVault {
  VaultChats get chats;

  VaultKnowledge get knowledge;

  VaultSettings get settings;

  Future<StorageUsage> storageUsage();

  Future<void> eraseAll();

  Future<void> close();
}

Future<LocalDataVault> openLocalDataVault({
  required String databasePath,
  DateTime Function()? clock,
}) async {
  final database = databasePath == ':memory:'
      ? sqlite3.openInMemory()
      : sqlite3.open(databasePath);
  final vault = _SqliteLocalDataVault(database, clock ?? DateTime.now);
  try {
    vault._openSchema();
    return vault;
  } on Object {
    database.close();
    rethrow;
  }
}

final class _SqliteLocalDataVault implements LocalDataVault, VaultChats {
  _SqliteLocalDataVault(this._database, this._clock);

  final DateTime Function() _clock;
  DateTime _now() => _clock().toUtc();

  static var _idSequence = 0;

  final Database _database;
  var _isClosed = false;

  @override
  VaultChats get chats => this;

  @override
  VaultKnowledge get knowledge => _SqliteVaultKnowledge(this);

  @override
  VaultSettings get settings => _SqliteVaultSettings(this);

  @override
  Future<StorageUsage> storageUsage() async {
    _ensureOpen();
    final sourceBytes =
        _database.select('''
      SELECT COALESCE(SUM(length(source_bytes)), 0) AS bytes
      FROM knowledge_items;
    ''').single['bytes']
            as int;
    final indexBytes =
        _database.select('''
      SELECT
        COALESCE((SELECT SUM(length(extracted_text)) FROM knowledge_items), 0) +
        COALESCE((
          SELECT SUM(
            length(text) + length(heading) + length(vector)
          ) FROM knowledge_passages
        ), 0) +
        COALESCE((
          SELECT SUM(length(stage) + length(artifact))
          FROM processing_checkpoints
        ), 0) AS bytes;
    ''').single['bytes']
            as int;
    final chatBytes =
        _database.select('''
      SELECT
        COALESCE((SELECT SUM(length(title)) FROM chats), 0) +
        COALESCE((
          SELECT SUM(length(user_text) + length(assistant_text)) FROM turns
        ), 0) +
        COALESCE((
          SELECT SUM(length(summary_text)) FROM context_summaries
        ), 0) +
        COALESCE((
          SELECT SUM(length(source_title)) FROM turn_source_scope
        ), 0) +
        COALESCE((
          SELECT SUM(
            length(source_title) + length(passage_text) + length(heading)
          ) FROM turn_evidence
        ), 0) +
        COALESCE((
          SELECT SUM(
            length(model_identifier) + length(model_revision) +
            length(model_metadata_json)
          ) FROM turn_provenance
        ), 0) AS bytes;
    ''').single['bytes']
            as int;
    return StorageUsage(
      chatBytes: chatBytes,
      knowledgeSourceBytes: sourceBytes,
      knowledgeIndexBytes: indexBytes,
    );
  }

  @override
  Future<void> eraseAll() async {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE;');
    try {
      _database.execute('DELETE FROM knowledge_passages_fts;');
      _database.execute('DELETE FROM chats;');
      _database.execute('DELETE FROM knowledge_items;');
      _database.execute('COMMIT;');
    } on Object catch (error) {
      _database.execute('ROLLBACK;');
      throw VaultWriteException(error);
    }
  }

  void _openSchema() {
    _database.execute('PRAGMA foreign_keys = ON;');
    final foundVersion =
        _database.select('PRAGMA user_version;').single['user_version'] as int;
    if (foundVersion > localDataVaultSchemaVersion) {
      throw UnsupportedVaultSchemaException(
        foundVersion: foundVersion,
        supportedVersion: localDataVaultSchemaVersion,
      );
    }
    if (foundVersion == 0) {
      final existingTables = _userTableNames();
      if (existingTables.isNotEmpty) {
        throw UnrecognizedVaultSchemaException(existingTables.toList()..sort());
      }
      _database.execute('BEGIN IMMEDIATE;');
      try {
        _createFreshSchema();
        _database.execute(
          'PRAGMA user_version = $localDataVaultSchemaVersion;',
        );
        _validateSchema();
        _database.execute('COMMIT;');
      } on Object {
        _database.execute('ROLLBACK;');
        rethrow;
      }
    } else if (foundVersion < localDataVaultSchemaVersion) {
      _migrateSchema(foundVersion);
    }
    _validateSchema();
  }

  Set<String> _userTableNames() => {
    for (final row in _database.select('''
      SELECT name
      FROM sqlite_schema
      WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
    '''))
      row['name'] as String,
  };

  void _migrateSchema(int foundVersion) {
    _database.execute('BEGIN IMMEDIATE;');
    try {
      var version = foundVersion;
      while (version < localDataVaultSchemaVersion) {
        switch (version) {
          case 1:
            _createChatLifecycleSchema();
            version = 2;
          case 2:
            _database.execute('ALTER TABLE turns ADD COLUMN failure TEXT;');
            version = 3;
          default:
            throw InvalidVaultSchemaException(const []);
        }
      }
      _database.execute('PRAGMA user_version = $version;');
      _validateSchema();
      _database.execute('COMMIT;');
    } on Object {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _validateSchema() {
    const requiredTables = {
      'chats',
      'knowledge_items',
      'processing_checkpoints',
      'knowledge_passages',
      'chat_selected_sources',
      'turns',
      'turn_provenance',
      'turn_source_scope',
      'turn_evidence',
      'turn_citations',
      'context_summaries',
      'vault_settings',
      'knowledge_passages_fts',
      'chat_workspace_state',
    };
    final missingTables = requiredTables.difference(_userTableNames()).toList()
      ..sort();
    if (missingTables.isNotEmpty) {
      throw InvalidVaultSchemaException(missingTables);
    }
    final columns = {
      for (final row in _database.select('PRAGMA table_info(chats);'))
        row['name'] as String,
    };
    if (!columns.containsAll({
      'revision',
      'manually_titled',
      'deletion_deadline',
    })) {
      throw const InvalidVaultSchemaException(['chats lifecycle columns']);
    }
    if (!_database
        .select('PRAGMA table_info(turns);')
        .any((row) => row['name'] == 'failure')) {
      throw const InvalidVaultSchemaException(['turn failure column']);
    }
  }

  void _createFreshSchema() {
    _database.execute('''
      CREATE TABLE chats (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        mode TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE knowledge_items (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_name TEXT,
        source_bytes BLOB NOT NULL,
        page_count INTEGER NOT NULL DEFAULT 0,
        extracted_text TEXT,
        fingerprint TEXT NOT NULL UNIQUE,
        processing_state TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        indexed_at TEXT
      );

      CREATE TABLE processing_checkpoints (
        knowledge_item_id TEXT PRIMARY KEY
          REFERENCES knowledge_items(id) ON DELETE CASCADE,
        stage TEXT NOT NULL,
        completed_units INTEGER NOT NULL,
        total_units INTEGER NOT NULL,
        artifact BLOB NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE knowledge_passages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        knowledge_item_id TEXT NOT NULL
          REFERENCES knowledge_items(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        text TEXT NOT NULL,
        heading TEXT NOT NULL,
        page INTEGER,
        token_count INTEGER NOT NULL,
        vector BLOB NOT NULL,
        vector_scale REAL NOT NULL,
        UNIQUE (knowledge_item_id, ordinal)
      );

      CREATE TABLE chat_selected_sources (
        chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
        knowledge_item_id TEXT NOT NULL
          REFERENCES knowledge_items(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        PRIMARY KEY (chat_id, knowledge_item_id),
        UNIQUE (chat_id, ordinal)
      );

      CREATE TABLE turns (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        user_text TEXT NOT NULL,
        assistant_text TEXT NOT NULL,
        outcome TEXT NOT NULL,
        failure TEXT,
        created_at TEXT NOT NULL,
        UNIQUE (chat_id, ordinal)
      );

      CREATE TABLE turn_provenance (
        turn_id TEXT PRIMARY KEY REFERENCES turns(id) ON DELETE CASCADE,
        mode TEXT NOT NULL,
        model_identifier TEXT NOT NULL,
        model_revision TEXT NOT NULL,
        model_metadata_json TEXT NOT NULL
      );

      CREATE TABLE turn_source_scope (
        turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL,
        source_title TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        PRIMARY KEY (turn_id, source_id),
        UNIQUE (turn_id, ordinal)
      );

      CREATE TABLE turn_evidence (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL,
        source_title TEXT NOT NULL,
        passage_text TEXT NOT NULL,
        heading TEXT NOT NULL,
        page INTEGER,
        rank INTEGER NOT NULL,
        UNIQUE (turn_id, rank)
      );

      CREATE TABLE turn_citations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
        evidence_id INTEGER NOT NULL
          REFERENCES turn_evidence(id) ON DELETE CASCADE,
        display_order INTEGER NOT NULL,
        UNIQUE (turn_id, display_order)
      );

      CREATE TABLE context_summaries (
        chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
        summarized_through_ordinal INTEGER NOT NULL,
        summary_text TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE vault_settings (
        singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
        retention_policy TEXT NOT NULL,
        biometric_lock_enabled INTEGER NOT NULL,
        lock_delay TEXT NOT NULL
      );

      CREATE VIRTUAL TABLE knowledge_passages_fts USING fts5(
        passage_id UNINDEXED,
        knowledge_item_id UNINDEXED,
        heading,
        text
      );

      INSERT INTO vault_settings (
        singleton_id, retention_policy, biometric_lock_enabled, lock_delay
      ) VALUES (1, 'manual', 0, 'immediate');
    ''');
    _createChatLifecycleSchema();
  }

  void _createChatLifecycleSchema() {
    _database.execute('''
      ALTER TABLE chats ADD COLUMN manually_titled INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE chats ADD COLUMN deletion_deadline TEXT;
      ALTER TABLE chats ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
      CREATE TABLE chat_workspace_state (
        singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
        current_chat_id TEXT REFERENCES chats(id) ON DELETE SET NULL
      );
      INSERT INTO chat_workspace_state VALUES (1, NULL);
      CREATE UNIQUE INDEX one_generating_turn ON turns(outcome)
        WHERE outcome = 'generating';
      CREATE INDEX chat_activity ON chats(updated_at);
    ''');
  }

  @override
  Future<ChatRecord> createChat() async {
    _ensureOpen();
    final now = _now();
    final chat = ChatRecord(
      id: '${now.microsecondsSinceEpoch.toRadixString(36)}-${_idSequence++}',
      title: 'New Chat',
      createdAt: now,
      updatedAt: now,
      mode: ChatMode.general,
      selectedSourceIds: const [],
    );
    _database.execute(
      '''
        INSERT INTO chats (id, title, mode, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?);
      ''',
      [
        chat.id,
        chat.title,
        _chatModeValue(chat.mode),
        chat.createdAt.toIso8601String(),
        chat.updatedAt.toIso8601String(),
      ],
    );
    return chat;
  }

  void _requireVisibleChat(String id) {
    _ensureOpen();
    if (_database.select(
      'SELECT 1 FROM chats WHERE id = ? AND deletion_deadline IS NULL;',
      [id],
    ).isEmpty) {
      throw StateError('Chat is unavailable.');
    }
  }

  @override
  Future<String?> currentChatId() async {
    _ensureOpen();
    return _database
            .select('SELECT current_chat_id FROM chat_workspace_state;')
            .single['current_chat_id']
        as String?;
  }

  @override
  Future<void> selectChat(String? id) async {
    _ensureOpen();
    if (id != null) _requireVisibleChat(id);
    _database.execute('UPDATE chat_workspace_state SET current_chat_id = ?;', [
      id,
    ]);
  }

  T _transaction<T>(T Function() action) {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action();
      _database.execute('COMMIT;');
      return result;
    } on Object {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<void> renameChat(String chatId, String title) async {
    _requireVisibleChat(chatId);
    final clean = title.trim();
    if (clean.isEmpty) throw ArgumentError('Enter a chat title.');
    _database.execute(
      'UPDATE chats SET title = ?, manually_titled = 1, updated_at = ?, revision = revision + 1 WHERE id = ?;',
      [clean, _now().toIso8601String(), chatId],
    );
  }

  @override
  Future<void> deleteFromTurn(String chatId, String turnId) async {
    _requireVisibleChat(chatId);
    _transaction(() {
      final rows = _database.select(
        'SELECT ordinal FROM turns WHERE id = ? AND chat_id = ?;',
        [turnId, chatId],
      );
      if (rows.isEmpty) throw StateError('Turn is unavailable.');
      final ordinal = rows.single['ordinal'] as int;
      _database.execute(
        'DELETE FROM turns WHERE chat_id = ? AND ordinal >= ?;',
        [chatId, ordinal],
      );
      // A summary that contains removed turns must never reach the next prompt.
      _database.execute(
        'DELETE FROM context_summaries WHERE chat_id = ? AND summarized_through_ordinal >= ?;',
        [chatId, ordinal],
      );
      _database.execute(
        'UPDATE chats SET updated_at = ?, revision = revision + 1 WHERE id = ?;',
        [_now().toIso8601String(), chatId],
      );
    });
  }

  @override
  Future<void> stageDeletion(String chatId, DateTime deadline) async {
    _requireVisibleChat(chatId);
    _transaction(() {
      _database.execute(
        "UPDATE turns SET outcome = 'interrupted' WHERE chat_id = ? AND outcome = 'generating';",
        [chatId],
      );
      _database.execute(
        'UPDATE chats SET deletion_deadline = ?, revision = revision + 1 WHERE id = ?;',
        [deadline.toUtc().toIso8601String(), chatId],
      );
    });
  }

  @override
  Future<bool> undoDeletion(String chatId) async {
    _ensureOpen();
    _database.execute(
      'UPDATE chats SET deletion_deadline = NULL, updated_at = ?, revision = revision + 1 WHERE id = ? AND deletion_deadline > ?;',
      [_now().toIso8601String(), chatId, _now().toIso8601String()],
    );
    return _database.updatedRows == 1;
  }

  DateTime? _cutoff(RetentionPolicy policy) => switch (policy) {
    RetentionPolicy.manual => null,
    RetentionPolicy.thirtyDays => _now().subtract(const Duration(days: 30)),
    RetentionPolicy.ninetyDays => _now().subtract(const Duration(days: 90)),
  };

  @override
  Future<List<ChatRecord>> retentionCandidates(RetentionPolicy policy) async {
    _ensureOpen();
    final cutoff = _cutoff(policy);
    if (cutoff == null) return [];
    return [
      for (final row in _database.select(
        """SELECT * FROM chats WHERE deletion_deadline IS NULL AND updated_at <= ?
           AND NOT EXISTS (SELECT 1 FROM turns WHERE chat_id = chats.id AND outcome = 'generating');""",
        [cutoff.toIso8601String()],
      ))
        _chatFromRow(row),
    ];
  }

  @override
  Future<void> applyRetention(
    RetentionPolicy policy,
    List<ChatRecord> candidates,
  ) async {
    _transaction(() {
      _database.execute(
        'UPDATE vault_settings SET retention_policy = ? WHERE singleton_id = 1;',
        [_retentionPolicyValue(policy)],
      );
      final cutoff = _cutoff(policy);
      if (cutoff == null) return;
      for (final chat in candidates) {
        // Confirmation applies only to previewed chats with unchanged activity.
        _database.execute(
          """DELETE FROM chats WHERE id = ? AND revision = ? AND updated_at <= ?
             AND deletion_deadline IS NULL
             AND NOT EXISTS (SELECT 1 FROM turns WHERE chat_id = chats.id AND outcome = 'generating');""",
          [chat.id, chat.revision, cutoff.toIso8601String()],
        );
      }
    });
  }

  @override
  Future<void> reap() async {
    _transaction(() {
      _database.execute('DELETE FROM chats WHERE deletion_deadline <= ?;', [
        _now().toIso8601String(),
      ]);
      final policy = _retentionPolicyFromValue(
        _database
                .select('SELECT retention_policy FROM vault_settings;')
                .single['retention_policy']
            as String,
      );
      final cutoff = _cutoff(policy);
      if (cutoff != null) {
        _database.execute(
          """DELETE FROM chats WHERE deletion_deadline IS NULL AND updated_at <= ?
             AND NOT EXISTS (SELECT 1 FROM turns WHERE chat_id = chats.id AND outcome = 'generating');""",
          [cutoff.toIso8601String()],
        );
      }
    });
  }

  @override
  Future<DateTime?> nextDeletionDeadline() async {
    _ensureOpen();
    final value = _database
        .select('SELECT MIN(deletion_deadline) AS deadline FROM chats;')
        .single['deadline'];
    return value is String ? DateTime.parse(value) : null;
  }

  @override
  Future<void> finishTurn(
    String turnId,
    String text,
    TurnOutcome outcome, {
    TurnFailure? failure,
  }) async {
    if (failure != null && outcome != TurnOutcome.failed) {
      throw ArgumentError('Only failed turns may have a failure reason.');
    }
    _transaction(() {
      final rows = _database.select(
        """SELECT chat_id FROM turns WHERE id = ? AND outcome = 'generating'
           AND EXISTS (SELECT 1 FROM chats WHERE chats.id = chat_id AND deletion_deadline IS NULL);""",
        [turnId],
      );
      if (rows.isEmpty) throw StateError('Turn is no longer generating.');
      _database.execute(
        'UPDATE turns SET assistant_text = ?, outcome = ?, failure = ? WHERE id = ?;',
        [text, _turnOutcomeValue(outcome), failure?.name, turnId],
      );
      _database.execute(
        'UPDATE chats SET updated_at = ?, revision = revision + 1 WHERE id = ?;',
        [_now().toIso8601String(), rows.single['chat_id']],
      );
    });
  }

  @override
  Future<void> recoverInterruptedTurns() async {
    _ensureOpen();
    _database.execute(
      "UPDATE turns SET outcome = 'interrupted' WHERE outcome = 'generating';",
    );
  }

  @override
  Future<List<ChatRecord>> listChats() async {
    _ensureOpen();
    final rows = _database.select('''
      SELECT id, title, mode, created_at, updated_at, revision
      FROM chats
      WHERE deletion_deadline IS NULL
      ORDER BY updated_at DESC, id DESC;
    ''');
    return [for (final row in rows) _chatFromRow(row)];
  }

  @override
  Future<void> updateScope({
    required String chatId,
    required ChatMode mode,
    required List<String> selectedSourceIds,
  }) async {
    _ensureOpen();
    _requireVisibleChat(chatId);
    _database.execute('BEGIN IMMEDIATE;');
    try {
      _database.execute(
        'DELETE FROM chat_selected_sources WHERE chat_id = ?;',
        [chatId],
      );
      for (var ordinal = 0; ordinal < selectedSourceIds.length; ordinal += 1) {
        _database.execute(
          '''
            INSERT INTO chat_selected_sources (
              chat_id, knowledge_item_id, ordinal
            ) VALUES (?, ?, ?);
          ''',
          [chatId, selectedSourceIds[ordinal], ordinal],
        );
      }
      _database.execute(
        'UPDATE chats SET mode = ?, updated_at = ?, revision = revision + 1 WHERE id = ?;',
        [_chatModeValue(mode), _now().toIso8601String(), chatId],
      );
      if (_database.updatedRows != 1) {
        throw StateError('Chat not found: $chatId');
      }
      _database.execute('COMMIT;');
    } on Object catch (error) {
      _database.execute('ROLLBACK;');
      throw VaultWriteException(error);
    }
  }

  @override
  Future<TurnRecord> appendTurn({
    required String chatId,
    required String userText,
    required String assistantText,
    required TurnOutcome outcome,
    required ChatMode mode,
    required List<String> sourceScopeIds,
    required List<int> evidencePassageIds,
    required List<int> citationEvidenceIndexes,
    required ModelSnapshot model,
  }) async {
    _ensureOpen();
    _requireVisibleChat(chatId);
    final now = _now();
    final turnId =
        '${now.microsecondsSinceEpoch.toRadixString(36)}-${_idSequence++}';
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final ordinalRow = _database
          .select(
            '''
          SELECT COALESCE(MAX(ordinal), -1) + 1 AS next_ordinal
          FROM turns
          WHERE chat_id = ?;
        ''',
            [chatId],
          )
          .single;
      final ordinal = ordinalRow['next_ordinal'] as int;
      if (ordinal == 0) {
        final compact = userText.trim().replaceAll(RegExp(r'\s+'), ' ');
        final title = String.fromCharCodes(compact.runes.take(60));
        _database.execute(
          'UPDATE chats SET title = ? WHERE id = ? AND manually_titled = 0;',
          [title.isEmpty ? 'New Chat' : title, chatId],
        );
      }
      _database.execute(
        '''
          INSERT INTO turns (
            id, chat_id, ordinal, user_text, assistant_text, outcome, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          turnId,
          chatId,
          ordinal,
          userText,
          assistantText,
          _turnOutcomeValue(outcome),
          now.toIso8601String(),
        ],
      );
      _database.execute(
        '''
          INSERT INTO turn_provenance (
            turn_id, mode, model_identifier, model_revision,
            model_metadata_json
          ) VALUES (?, ?, ?, ?, ?);
        ''',
        [
          turnId,
          _chatModeValue(mode),
          model.identifier,
          model.revision,
          jsonEncode(model.metadata),
        ],
      );

      for (var index = 0; index < sourceScopeIds.length; index += 1) {
        final sourceId = sourceScopeIds[index];
        final sourceRows = _database.select(
          'SELECT title FROM knowledge_items WHERE id = ?;',
          [sourceId],
        );
        if (sourceRows.isEmpty) {
          throw StateError('Knowledge item not found: $sourceId');
        }
        _database.execute(
          '''
            INSERT INTO turn_source_scope (
              turn_id, source_id, source_title, ordinal
            ) VALUES (?, ?, ?, ?);
          ''',
          [turnId, sourceId, sourceRows.single['title'], index],
        );
      }

      final evidenceIds = <int>[];
      for (var rank = 0; rank < evidencePassageIds.length; rank += 1) {
        final passageRows = _database.select(
          '''
            SELECT
              knowledge_passages.text,
              knowledge_passages.heading,
              knowledge_passages.page,
              knowledge_items.id AS source_id,
              knowledge_items.title AS source_title
            FROM knowledge_passages
            JOIN knowledge_items
              ON knowledge_items.id = knowledge_passages.knowledge_item_id
            WHERE knowledge_passages.id = ?
              AND knowledge_items.processing_state = ?;
          ''',
          [
            evidencePassageIds[rank],
            _knowledgeProcessingStateValue(KnowledgeProcessingState.indexed),
          ],
        );
        if (passageRows.isEmpty) {
          throw StateError(
            'Indexed evidence passage not found: ${evidencePassageIds[rank]}',
          );
        }
        final passage = passageRows.single;
        final sourceId = passage['source_id'] as String;
        if (!sourceScopeIds.contains(sourceId)) {
          throw StateError('Evidence is outside the turn source scope.');
        }
        _database.execute(
          '''
            INSERT INTO turn_evidence (
              turn_id, source_id, source_title, passage_text, heading, page, rank
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
          ''',
          [
            turnId,
            sourceId,
            passage['source_title'],
            passage['text'],
            passage['heading'],
            passage['page'],
            rank,
          ],
        );
        evidenceIds.add(_database.lastInsertRowId);
      }

      for (
        var displayOrder = 0;
        displayOrder < citationEvidenceIndexes.length;
        displayOrder += 1
      ) {
        final evidenceIndex = citationEvidenceIndexes[displayOrder];
        if (evidenceIndex < 0 || evidenceIndex >= evidenceIds.length) {
          throw RangeError.index(evidenceIndex, evidenceIds, 'evidenceIndex');
        }
        _database.execute(
          '''
            INSERT INTO turn_citations (
              turn_id, evidence_id, display_order
            ) VALUES (?, ?, ?);
          ''',
          [turnId, evidenceIds[evidenceIndex], displayOrder],
        );
      }
      _database.execute(
        'UPDATE chats SET updated_at = ?, revision = revision + 1 WHERE id = ?;',
        [now.toIso8601String(), chatId],
      );
      _database.execute('COMMIT;');
    } on Object catch (error) {
      _database.execute('ROLLBACK;');
      throw VaultWriteException(error);
    }
    return (await listTurns(chatId)).firstWhere((turn) => turn.id == turnId);
  }

  @override
  Future<List<TurnRecord>> listTurns(String chatId) async {
    _ensureOpen();
    _requireVisibleChat(chatId);
    final turnRows = _database.select(
      '''
        SELECT
          turns.id,
          turns.chat_id,
          turns.ordinal,
          turns.user_text,
          turns.assistant_text,
          turns.outcome,
          turns.failure,
          turns.created_at,
          turn_provenance.mode,
          turn_provenance.model_identifier,
          turn_provenance.model_revision,
          turn_provenance.model_metadata_json
        FROM turns
        JOIN turn_provenance ON turn_provenance.turn_id = turns.id
        WHERE turns.chat_id = ?
        ORDER BY turns.ordinal;
      ''',
      [chatId],
    );
    return [for (final row in turnRows) _turnFromRow(row)];
  }

  @override
  Future<void> saveContextSummary({
    required String chatId,
    required int summarizedThroughOrdinal,
    required String text,
  }) async {
    _ensureOpen();
    _database.execute(
      '''
        INSERT INTO context_summaries (
          chat_id, summarized_through_ordinal, summary_text, updated_at
        ) VALUES (?, ?, ?, ?)
        ON CONFLICT (chat_id) DO UPDATE SET
          summarized_through_ordinal = excluded.summarized_through_ordinal,
          summary_text = excluded.summary_text,
          updated_at = excluded.updated_at;
      ''',
      [
        chatId,
        summarizedThroughOrdinal,
        text,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<ContextSummaryRecord?> getContextSummary(String chatId) async {
    _ensureOpen();
    final rows = _database.select(
      '''
        SELECT chat_id, summarized_through_ordinal, summary_text, updated_at
        FROM context_summaries
        WHERE chat_id = ?;
      ''',
      [chatId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return ContextSummaryRecord(
      chatId: row['chat_id'] as String,
      summarizedThroughOrdinal: row['summarized_through_ordinal'] as int,
      text: row['summary_text'] as String,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  TurnRecord _turnFromRow(Row row) {
    final turnId = row['id'] as String;
    final sourceRows = _database.select(
      '''
        SELECT
          source_id,
          source_title,
          NOT EXISTS (
            SELECT 1
            FROM knowledge_items
            WHERE knowledge_items.id = turn_source_scope.source_id
          ) AS source_deleted
        FROM turn_source_scope
        WHERE turn_id = ?
        ORDER BY ordinal;
      ''',
      [turnId],
    );
    final evidenceRows = _database.select(
      '''
        SELECT
          id,
          source_id,
          source_title,
          passage_text,
          heading,
          page,
          rank,
          NOT EXISTS (
            SELECT 1
            FROM knowledge_items
            WHERE knowledge_items.id = turn_evidence.source_id
          ) AS source_deleted
        FROM turn_evidence
        WHERE turn_id = ?
        ORDER BY rank;
      ''',
      [turnId],
    );
    final citationRows = _database.select(
      '''
        SELECT id, evidence_id, display_order
        FROM turn_citations
        WHERE turn_id = ?
        ORDER BY display_order;
      ''',
      [turnId],
    );
    final metadata = jsonDecode(row['model_metadata_json'] as String);
    return TurnRecord(
      id: turnId,
      chatId: row['chat_id'] as String,
      ordinal: row['ordinal'] as int,
      userText: row['user_text'] as String,
      assistantText: row['assistant_text'] as String,
      outcome: _turnOutcomeFromValue(row['outcome'] as String),
      failure: row['failure'] == null
          ? null
          : TurnFailure.values.byName(row['failure'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
      provenance: TurnProvenance(
        mode: _chatModeFromValue(row['mode'] as String),
        sourceScope: [
          for (final source in sourceRows)
            TurnSourceSnapshot(
              id: source['source_id'] as String,
              title: source['source_title'] as String,
              sourceDeleted: source['source_deleted'] == 1,
            ),
        ],
        evidence: [
          for (final evidence in evidenceRows)
            TurnEvidenceSnapshot(
              id: evidence['id'] as int,
              sourceId: evidence['source_id'] as String,
              sourceTitle: evidence['source_title'] as String,
              passageText: evidence['passage_text'] as String,
              heading: evidence['heading'] as String,
              page: evidence['page'] as int?,
              rank: evidence['rank'] as int,
              sourceDeleted: evidence['source_deleted'] == 1,
            ),
        ],
        citations: [
          for (final citation in citationRows)
            TurnCitationSnapshot(
              id: citation['id'] as int,
              evidenceId: citation['evidence_id'] as int,
              displayOrder: citation['display_order'] as int,
            ),
        ],
        model: ModelSnapshot(
          identifier: row['model_identifier'] as String,
          revision: row['model_revision'] as String,
          metadata: metadata is Map<String, Object?> ? metadata : const {},
        ),
      ),
    );
  }

  ChatRecord _chatFromRow(Row row) {
    final id = row['id'] as String;
    final selectedRows = _database.select(
      '''
        SELECT knowledge_item_id
        FROM chat_selected_sources
        WHERE chat_id = ?
        ORDER BY ordinal;
      ''',
      [id],
    );
    return ChatRecord(
      id: id,
      title: row['title'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      mode: _chatModeFromValue(row['mode'] as String),
      revision: row['revision'] as int,
      selectedSourceIds: [
        for (final selected in selectedRows)
          selected['knowledge_item_id'] as String,
      ],
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _database.close();
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('The local data vault is closed.');
    }
  }
}

final class _SqliteVaultKnowledge implements VaultKnowledge {
  const _SqliteVaultKnowledge(this._vault);

  final _SqliteLocalDataVault _vault;

  @override
  Future<KnowledgeItemRecord> beginProcessing({
    required String title,
    required KnowledgeSourceType sourceType,
    required Uint8List sourceBytes,
    String? sourceName,
    required String fingerprint,
  }) async {
    _vault._ensureOpen();
    final now = DateTime.now().toUtc();
    final id =
        '${now.microsecondsSinceEpoch.toRadixString(36)}-${_SqliteLocalDataVault._idSequence++}';
    _vault._database.execute(
      '''
        INSERT INTO knowledge_items (
          id, title, source_type, source_name, source_bytes, fingerprint,
          processing_state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        id,
        title,
        _knowledgeSourceTypeValue(sourceType),
        sourceName,
        sourceBytes,
        fingerprint,
        _knowledgeProcessingStateValue(KnowledgeProcessingState.processing),
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    return get(id);
  }

  @override
  Future<void> saveCheckpoint({
    required String knowledgeItemId,
    required String stage,
    required int completedUnits,
    required int totalUnits,
    required Uint8List artifact,
  }) async {
    _vault._ensureOpen();
    final now = DateTime.now().toUtc().toIso8601String();
    _vault._database.execute(
      '''
        INSERT INTO processing_checkpoints (
          knowledge_item_id, stage, completed_units, total_units,
          artifact, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (knowledge_item_id) DO UPDATE SET
          stage = excluded.stage,
          completed_units = excluded.completed_units,
          total_units = excluded.total_units,
          artifact = excluded.artifact,
          updated_at = excluded.updated_at;
      ''',
      [knowledgeItemId, stage, completedUnits, totalUnits, artifact, now],
    );
  }

  @override
  Future<void> completeIndex({
    required String knowledgeItemId,
    required String extractedText,
    int pageCount = 0,
    required List<EvidencePassageDraft> passages,
  }) async {
    _vault._ensureOpen();
    _vault._database.execute('BEGIN IMMEDIATE;');
    try {
      for (final passage in passages) {
        _vault._database.execute(
          '''
            INSERT INTO knowledge_passages (
              knowledge_item_id, ordinal, text, heading, page, token_count,
              vector, vector_scale
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          [
            knowledgeItemId,
            passage.ordinal,
            passage.text,
            passage.heading,
            passage.page,
            passage.tokenCount,
            passage.vector,
            passage.vectorScale,
          ],
        );
        final passageId = _vault._database.lastInsertRowId;
        _vault._database.execute(
          '''
            INSERT INTO knowledge_passages_fts (
              passage_id, knowledge_item_id, heading, text
            ) VALUES (?, ?, ?, ?);
          ''',
          [passageId, knowledgeItemId, passage.heading, passage.text],
        );
      }
      final now = DateTime.now().toUtc().toIso8601String();
      _vault._database.execute(
        '''
          UPDATE knowledge_items
          SET extracted_text = ?, page_count = ?, processing_state = ?,
              updated_at = ?, indexed_at = ?
          WHERE id = ?;
        ''',
        [
          extractedText,
          pageCount,
          _knowledgeProcessingStateValue(KnowledgeProcessingState.indexed),
          now,
          now,
          knowledgeItemId,
        ],
      );
      if (_vault._database.updatedRows != 1) {
        throw StateError('Knowledge item not found: $knowledgeItemId');
      }
      _vault._database.execute(
        'DELETE FROM processing_checkpoints WHERE knowledge_item_id = ?;',
        [knowledgeItemId],
      );
      _vault._database.execute('COMMIT;');
    } on Object catch (error) {
      _vault._database.execute('ROLLBACK;');
      throw VaultWriteException(error);
    }
  }

  @override
  Future<KnowledgeItemRecord> get(String knowledgeItemId) async {
    _vault._ensureOpen();
    final rows = _vault._database.select(
      '''
        SELECT
          knowledge_items.id,
          knowledge_items.title,
          knowledge_items.source_type,
          knowledge_items.source_name,
          knowledge_items.page_count,
          knowledge_items.fingerprint,
          knowledge_items.processing_state,
          knowledge_items.created_at,
          knowledge_items.updated_at,
          knowledge_items.indexed_at,
          processing_checkpoints.stage AS checkpoint_stage,
          processing_checkpoints.completed_units,
          processing_checkpoints.total_units,
          processing_checkpoints.artifact,
          processing_checkpoints.updated_at AS checkpoint_updated_at
        FROM knowledge_items
        LEFT JOIN processing_checkpoints
          ON processing_checkpoints.knowledge_item_id = knowledge_items.id
        WHERE knowledge_items.id = ?;
      ''',
      [knowledgeItemId],
    );
    if (rows.isEmpty) {
      throw StateError('Knowledge item not found: $knowledgeItemId');
    }
    final row = rows.single;
    final checkpointStage = row['checkpoint_stage'] as String?;
    return KnowledgeItemRecord(
      id: row['id'] as String,
      title: row['title'] as String,
      sourceType: _knowledgeSourceTypeFromValue(row['source_type'] as String),
      sourceName: row['source_name'] as String?,
      pageCount: row['page_count'] as int,
      fingerprint: row['fingerprint'] as String,
      processingState: _knowledgeProcessingStateFromValue(
        row['processing_state'] as String,
      ),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      indexedAt: switch (row['indexed_at']) {
        final String value => DateTime.parse(value),
        _ => null,
      },
      checkpoint: checkpointStage == null
          ? null
          : ProcessingCheckpoint(
              stage: checkpointStage,
              completedUnits: row['completed_units'] as int,
              totalUnits: row['total_units'] as int,
              artifact: row['artifact'] as Uint8List,
              updatedAt: DateTime.parse(row['checkpoint_updated_at'] as String),
            ),
    );
  }

  @override
  Future<List<KnowledgeItemRecord>> list() async {
    _vault._ensureOpen();
    final rows = _vault._database.select('''
      SELECT id
      FROM knowledge_items
      ORDER BY updated_at DESC, id DESC;
    ''');
    final items = <KnowledgeItemRecord>[];
    for (final row in rows) {
      items.add(await get(row['id'] as String));
    }
    return items;
  }

  @override
  Future<void> delete(String knowledgeItemId) async {
    _vault._ensureOpen();
    _vault._database.execute('BEGIN IMMEDIATE;');
    try {
      _vault._database.execute(
        'DELETE FROM knowledge_passages_fts WHERE knowledge_item_id = ?;',
        [knowledgeItemId],
      );
      _vault._database.execute('DELETE FROM knowledge_items WHERE id = ?;', [
        knowledgeItemId,
      ]);
      if (_vault._database.updatedRows != 1) {
        throw StateError('Knowledge item not found: $knowledgeItemId');
      }
      _vault._database.execute('COMMIT;');
    } on Object catch (error) {
      _vault._database.execute('ROLLBACK;');
      throw VaultWriteException(error);
    }
  }

  @override
  Future<List<StoredEvidencePassage>> listIndexedEvidence(
    String knowledgeItemId,
  ) async {
    _vault._ensureOpen();
    final rows = _vault._database.select(
      '''
        SELECT
          knowledge_passages.id,
          knowledge_passages.knowledge_item_id,
          knowledge_passages.ordinal,
          knowledge_passages.text,
          knowledge_passages.heading,
          knowledge_passages.page,
          knowledge_passages.token_count
        FROM knowledge_passages
        JOIN knowledge_items
          ON knowledge_items.id = knowledge_passages.knowledge_item_id
        WHERE knowledge_passages.knowledge_item_id = ?
          AND knowledge_items.processing_state = ?
        ORDER BY knowledge_passages.ordinal;
      ''',
      [
        knowledgeItemId,
        _knowledgeProcessingStateValue(KnowledgeProcessingState.indexed),
      ],
    );
    return [
      for (final row in rows)
        StoredEvidencePassage(
          id: row['id'] as int,
          knowledgeItemId: row['knowledge_item_id'] as String,
          ordinal: row['ordinal'] as int,
          text: row['text'] as String,
          heading: row['heading'] as String,
          page: row['page'] as int?,
          tokenCount: row['token_count'] as int,
        ),
    ];
  }
}

final class _SqliteVaultSettings implements VaultSettings {
  const _SqliteVaultSettings(this._vault);

  final _SqliteLocalDataVault _vault;

  @override
  Future<VaultSettingsRecord> get() async {
    _vault._ensureOpen();
    final row = _vault._database.select('''
      SELECT retention_policy, biometric_lock_enabled, lock_delay
      FROM vault_settings
      WHERE singleton_id = 1;
    ''').single;
    return VaultSettingsRecord(
      retentionPolicy: _retentionPolicyFromValue(
        row['retention_policy'] as String,
      ),
      biometricLockEnabled: row['biometric_lock_enabled'] == 1,
      lockDelay: _appLockDelayFromValue(row['lock_delay'] as String),
    );
  }

  @override
  Future<void> update({
    required RetentionPolicy retentionPolicy,
    required bool biometricLockEnabled,
    required AppLockDelay lockDelay,
  }) async {
    _vault._ensureOpen();
    _vault._database.execute(
      '''
        UPDATE vault_settings
        SET retention_policy = ?, biometric_lock_enabled = ?, lock_delay = ?
        WHERE singleton_id = 1;
      ''',
      [
        _retentionPolicyValue(retentionPolicy),
        biometricLockEnabled ? 1 : 0,
        _appLockDelayValue(lockDelay),
      ],
    );
  }
}

String _chatModeValue(ChatMode mode) => switch (mode) {
  ChatMode.general => 'general',
  ChatMode.knowledgeBase => 'knowledge-base',
};

ChatMode _chatModeFromValue(String value) => switch (value) {
  'knowledge-base' => ChatMode.knowledgeBase,
  _ => ChatMode.general,
};

String _turnOutcomeValue(TurnOutcome outcome) => switch (outcome) {
  TurnOutcome.generating => 'generating',
  TurnOutcome.completed => 'completed',
  TurnOutcome.stopped => 'stopped',
  TurnOutcome.interrupted => 'interrupted',
  TurnOutcome.failed => 'failed',
  TurnOutcome.insufficientEvidence => 'insufficient-evidence',
};

TurnOutcome _turnOutcomeFromValue(String value) => switch (value) {
  'generating' => TurnOutcome.generating,
  'stopped' => TurnOutcome.stopped,
  'interrupted' => TurnOutcome.interrupted,
  'failed' => TurnOutcome.failed,
  'insufficient-evidence' => TurnOutcome.insufficientEvidence,
  _ => TurnOutcome.completed,
};

String _retentionPolicyValue(RetentionPolicy policy) => switch (policy) {
  RetentionPolicy.manual => 'manual',
  RetentionPolicy.thirtyDays => 'thirty-days',
  RetentionPolicy.ninetyDays => 'ninety-days',
};

RetentionPolicy _retentionPolicyFromValue(String value) => switch (value) {
  'thirty-days' => RetentionPolicy.thirtyDays,
  'ninety-days' => RetentionPolicy.ninetyDays,
  _ => RetentionPolicy.manual,
};

String _appLockDelayValue(AppLockDelay delay) => switch (delay) {
  AppLockDelay.immediate => 'immediate',
  AppLockDelay.oneMinute => 'one-minute',
  AppLockDelay.fifteenMinutes => 'fifteen-minutes',
};

AppLockDelay _appLockDelayFromValue(String value) => switch (value) {
  'one-minute' => AppLockDelay.oneMinute,
  'fifteen-minutes' => AppLockDelay.fifteenMinutes,
  _ => AppLockDelay.immediate,
};

String _knowledgeSourceTypeValue(KnowledgeSourceType sourceType) =>
    switch (sourceType) {
      KnowledgeSourceType.pastedText => 'pasted-text',
      KnowledgeSourceType.pdf => 'pdf',
      KnowledgeSourceType.photo => 'photo',
    };

KnowledgeSourceType _knowledgeSourceTypeFromValue(String value) =>
    switch (value) {
      'pdf' => KnowledgeSourceType.pdf,
      'photo' => KnowledgeSourceType.photo,
      _ => KnowledgeSourceType.pastedText,
    };

String _knowledgeProcessingStateValue(KnowledgeProcessingState state) =>
    switch (state) {
      KnowledgeProcessingState.processing => 'processing',
      KnowledgeProcessingState.paused => 'paused',
      KnowledgeProcessingState.indexed => 'indexed',
      KnowledgeProcessingState.failed => 'failed',
      KnowledgeProcessingState.needsReindexing => 'needs-reindexing',
    };

KnowledgeProcessingState _knowledgeProcessingStateFromValue(String value) =>
    switch (value) {
      'paused' => KnowledgeProcessingState.paused,
      'indexed' => KnowledgeProcessingState.indexed,
      'failed' => KnowledgeProcessingState.failed,
      'needs-reindexing' => KnowledgeProcessingState.needsReindexing,
      _ => KnowledgeProcessingState.processing,
    };
