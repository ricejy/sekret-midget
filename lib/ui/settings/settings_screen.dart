import 'package:flutter/cupertino.dart';
import '../../core/chat/chat_workspace.dart';
import '../../core/platform/llm_backend.dart';
import '../../core/settings/app_protection.dart';
import '../../core/storage/local_data_vault.dart';

enum LocalDataAction { chats, knowledge, everything }

String modelStatus(LlmAvailability? status) => switch (status) {
  Available() => 'Ready · On-device Apple Intelligence',
  AppleIntelligenceNotEnabled() =>
    'Apple Intelligence is turned off. Enable it in iOS Settings → Apple Intelligence & Siri.',
  ModelNotReady() =>
    'Model assets are not ready. Check Apple Intelligence in iOS Settings and allow its setup to finish.',
  DeviceNotEligible() =>
    'This device or OS does not support the required on-device model.',
  _ => 'Checking on-device model…',
};

String retentionLabel(RetentionPolicy policy) => switch (policy) {
  RetentionPolicy.manual => 'Until I delete them',
  RetentionPolicy.thirtyDays => '30 days after last activity',
  RetentionPolicy.ninetyDays => '90 days after last activity',
};

String lockDelayLabel(AppLockDelay delay) => switch (delay) {
  AppLockDelay.immediate => 'Immediately',
  AppLockDelay.oneMinute => 'After 1 minute',
  AppLockDelay.fifteenMinutes => 'After 15 minutes',
};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.vault,
    required this.workspace,
    required this.protection,
    required this.model,
    required this.openSystemSettings,
    required this.deleteData,
  });
  final LocalDataVault vault;
  final ChatWorkspace workspace;
  final AppProtection protection;
  final LlmBackend model;
  final Future<void> Function() openSystemSettings;
  final Future<void> Function(LocalDataAction) deleteData;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  VaultSettingsRecord? _settings;
  StorageUsage? _usage;
  LlmAvailability? _model;
  Map<String, String> _diagnostics = const {};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final settings = await widget.vault.settings.get();
      final usage = await widget.vault.storageUsage();
      final model = await widget.model.availability();
      final diagnostics = await widget.protection.device.diagnostics();
      if (mounted) {
        setState(() {
          _settings = settings;
          _usage = usage;
          _model = model;
          _diagnostics = diagnostics;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not read Settings. Try again.');
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) await _refresh();
    } on Object {
      if (mounted) {
        await _report(
          widget.protection.error ??
              'The change could not be completed. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _report(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: const Text('Not completed'),
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  Future<T?> _choose<T>(
    String title,
    Iterable<T> values,
    String Function(T) label,
  ) => showCupertinoModalPopup<T>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: Text(title),
      actions: [
        for (final value in values)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, value),
            child: Text(label(value)),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ),
  );

  Future<void> _retention() => _run(() async {
    final policy = await _choose(
      'Keep chats',
      RetentionPolicy.values,
      retentionLabel,
    );
    if (policy == null || !mounted) return;
    final preview = await widget.workspace.previewRetention(policy);
    if (!mounted) return;
    if (await _confirm(
      'Change chat retention?',
      '${preview.affectedChats} chats will be permanently deleted now. ${retentionLabel(policy)}. Future cleanup runs when Sekret opens or resumes. Full chats are removed, not summarized.',
      'Apply',
    )) {
      await widget.workspace.confirmRetention(preview);
    }
  });

  Future<void> _delete(LocalDataAction action) => _run(() async {
    final (title, detail) = switch (action) {
      LocalDataAction.chats => (
        'Delete all chats?',
        'All chats, summaries, drafts, and saved source selections will be permanently removed. Your Knowledge Base stays.',
      ),
      LocalDataAction.knowledge => (
        'Delete entire Knowledge Base?',
        'All source originals, extracted text, indexes, and processing work will be permanently removed. Chats may retain sensitive information derived from these sources. Their citations will show Source deleted.',
      ),
      LocalDataAction.everything => (
        'Erase all local data?',
        'Every chat, summary, source selection, original, index, processing artifact, and draft will be permanently removed from Sekret. This cannot be undone. App-lock and retention preferences are kept. Device authentication is required.',
      ),
    };
    if (!await _confirm(
          title,
          detail,
          action == LocalDataAction.everything ? 'Erase All' : 'Delete',
        ) ||
        !mounted) {
      return;
    }
    // Authorization is performed in the app-owned operation, not in this view.
    await widget.deleteData(action);
  });

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: const CupertinoNavigationBar(middle: Text('Settings')),
    child: SafeArea(
      child: ListView(
        children: [
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          CupertinoListSection.insetGrouped(
            hasLeading: false,
            header: _header('ON-DEVICE MODEL'),
            children: [
              _detail(modelStatus(_model)),
              _button('Check readiness', () => _run(_refresh)),
              if (_model is! Available)
                _button(
                  'Open iOS Settings',
                  () => _run(widget.openSystemSettings),
                ),
              if (_model is! Available)
                _detail(
                  'History, preview, safe imports, Settings, and deletion remain available without generation.',
                ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            hasLeading: false,
            header: _header('PRIVACY'),
            children: [
              _detail(
                'Your chats, knowledge, search, and processing stay on this device. No account, cloud model, or sync.',
              ),
              _detail(
                'iOS sandbox and file protection protect stored data. App lock protects entry to Sekret; it is not database encryption. App-switcher snapshots are always hidden. Sekret sends no notifications.',
              ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            hasLeading: false,
            header: _header('APP LOCK'),
            children: [
              MergeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      const Expanded(child: Text('App lock')),
                      CupertinoSwitch(
                        value: _settings?.biometricLockEnabled ?? false,
                        onChanged: _busy || _settings == null
                            ? null
                            : (value) => _run(() async {
                                if (!await widget.protection.setEnabled(
                                  value,
                                )) {
                                  if (mounted) {
                                    await _report(widget.protection.error!);
                                  }
                                }
                              }),
                      ),
                    ],
                  ),
                ),
              ),
              _detail(
                'Require Face ID, Touch ID, or your device passcode to enter Sekret. Cold launches always lock, regardless of delay.',
              ),
              _button(
                'Lock delay',
                () => _run(() async {
                  final delay = await _choose(
                    'Lock after leaving Sekret',
                    AppLockDelay.values,
                    lockDelayLabel,
                  );
                  if (delay != null) await widget.protection.setDelay(delay);
                }),
                subtitle: _settings == null
                    ? null
                    : lockDelayLabel(_settings!.lockDelay),
              ),
              _detail(
                _diagnostics['authentication'] ??
                    'Device authentication status unavailable.',
              ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            hasLeading: false,
            header: _header('CHATS & STORAGE'),
            children: [
              _button(
                'Chat retention',
                _retention,
                subtitle: _settings == null
                    ? null
                    : retentionLabel(_settings!.retentionPolicy),
              ),
              _detail(
                _usage == null
                    ? 'Reading storage…'
                    : 'Chats: ${_bytes(_usage!.chatBytes)}\nKnowledge sources: ${_bytes(_usage!.knowledgeSourceBytes)}\nKnowledge indexes: ${_bytes(_usage!.knowledgeIndexBytes)}\nLogical content sizes; database overhead and system caches are not included.',
              ),
              _button('Refresh storage', () => _run(_refresh)),
              _button(
                'Delete all chats',
                () => _delete(LocalDataAction.chats),
                destructive: true,
              ),
              _button(
                'Delete entire Knowledge Base',
                () => _delete(LocalDataAction.knowledge),
                destructive: true,
              ),
              _button(
                'Erase all local data',
                () => _delete(LocalDataAction.everything),
                destructive: true,
              ),
            ],
          ),
          CupertinoListSection.insetGrouped(
            hasLeading: false,
            header: _header('ABOUT SEKRET'),
            children: [
              _detail(
                'Version ${_diagnostics['version'] ?? 'Unavailable'} (${_diagnostics['build'] ?? '—'})\n${_diagnostics['os'] ?? 'OS unavailable'}\nRuntime: Apple Foundation Models\nVault schema: $localDataVaultSchemaVersion',
              ),
              _detail(
                'Diagnostics show only app, OS, runtime, and capability status. No prompts, filenames, source titles, content, or device identifiers are collected or sent.',
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _header(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.normal,
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    ),
  );
  Widget _detail(String text) => SizedBox(
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Text(text),
    ),
  );
  Widget _button(
    String title,
    VoidCallback action, {
    String? subtitle,
    bool destructive = false,
  }) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    onPressed: _busy ? null : action,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: destructive ? CupertinoColors.systemRed : null,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const CupertinoListTileChevron(),
      ],
    ),
  );
  String _bytes(int value) => value < 1024
      ? '$value B'
      : value < 1024 * 1024
      ? '${(value / 1024).toStringAsFixed(1)} KB'
      : '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}
