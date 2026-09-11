import 'package:flutter/cupertino.dart';
import '../../core/platform/llm_backend.dart';
import '../../core/settings/app_protection.dart';
import 'settings_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.protection,
    required this.model,
    required this.openSystemSettings,
  });
  final AppProtection protection;
  final LlmBackend model;
  final Future<void> Function() openSystemSettings;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  LlmAvailability? _status;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    try {
      final status = await widget.model.availability();
      if (mounted) setState(() => _status = status);
    } on Object {
      if (mounted) setState(() => _status = const ModelNotReady());
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
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not save this choice. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: const CupertinoNavigationBar(
      middle: Text('Welcome to Sekret'),
    ),
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(CupertinoIcons.lock_shield, size: 48),
          const SizedBox(height: 24),
          const Text(
            'Your chats. Your knowledge. On this device.',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          const Text(
            'Chat generally or choose sources from your Knowledge Base. Chat history, document processing, search, and answers stay local. No account or cloud service is needed.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Import permissions are requested only when you choose to import. You control retention and deletion in Settings. App lock protects entry, not database encryption.',
          ),
          const SizedBox(height: 24),
          Text(modelStatus(_status)),
          if (_status is! Available) ...[
            const SizedBox(height: 12),
            const Text(
              'You can still browse history, preview and import knowledge where supported, and manage Settings.',
            ),
            CupertinoButton(
              onPressed: _busy ? null : () => _run(widget.openSystemSettings),
              child: const Text('Open iOS Settings'),
            ),
          ],
          CupertinoButton(
            onPressed: _busy ? null : _check,
            child: const Text('Check readiness'),
          ),
          CupertinoButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final enabled = await widget.protection.setEnabled(true);
                    if (mounted && !enabled) {
                      setState(() => _error = widget.protection.error);
                    }
                  }),
            child: Text(
              widget.protection.settings?.biometricLockEnabled == true
                  ? 'App lock enabled'
                  : 'Enable Face ID / Touch ID',
            ),
          ),
          if (_error != null) Text(_error!),
          const SizedBox(height: 12),
          CupertinoButton.filled(
            onPressed: _busy
                ? null
                : () => _run(widget.protection.finishOnboarding),
            child: const Text('Continue to Sekret'),
          ),
          const SizedBox(height: 12),
          const Text(
            'App lock is optional. You can change it later in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    ),
  );
}
