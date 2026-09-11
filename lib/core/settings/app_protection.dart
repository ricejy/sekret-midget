import 'dart:async';
import 'package:flutter/foundation.dart';
import '../platform/device_protection.dart';
import '../storage/local_data_vault.dart';

/// Fail-closed entry gate. Snapshot concealment is independent of this policy.
/// Uses monotonic elapsed time plus wall time to include device sleep. A
/// backwards wall-clock jump locks conservatively. Cold launches always lock.
final class AppProtection extends ChangeNotifier {
  AppProtection(
    this._settings,
    this.device, {
    Duration Function()? elapsed,
    DateTime Function()? wallClock,
  }) : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedDuration,
       _wallClock = wallClock ?? DateTime.now;

  final VaultSettings _settings;
  final DeviceProtection device;
  final Duration Function() _elapsed;
  final DateTime Function() _wallClock;
  VaultSettingsRecord? settings;
  bool locked = true;
  bool authenticating = false;
  bool _disposed = false;
  bool _background = false;
  bool _inactive = false;
  Completer<void>? _resumption;
  int _epoch = 0;
  Duration? _leftAt;
  DateTime? _leftAtWall;
  String? error;

  Future<void> initialize() async {
    settings = await _settings.get();
    locked = settings!.biometricLockEnabled;
    _notify();
  }

  void inactive() {
    _inactive = true;
    if (!authenticating) {
      _leftAt ??= _elapsed();
      _leftAtWall ??= _wallClock();
    }
  }

  void background() {
    _background = true;
    _leftAt ??= _elapsed();
    _leftAtWall ??= _wallClock();
    _epoch++;
    _resumption?.complete();
    _resumption = null;
    if (authenticating && settings?.biometricLockEnabled == true) locked = true;
    _notify();
  }

  void resumed() {
    _background = false;
    _inactive = false;
    _resumption?.complete();
    _resumption = null;
    final left = _leftAt;
    if (settings?.biometricLockEnabled == true && left != null) {
      final delay = switch (settings!.lockDelay) {
        AppLockDelay.immediate => Duration.zero,
        AppLockDelay.oneMinute => const Duration(minutes: 1),
        AppLockDelay.fifteenMinutes => const Duration(minutes: 15),
      };
      final wallDuration = _wallClock().difference(_leftAtWall!);
      if (_elapsed() - left >= delay ||
          wallDuration >= delay ||
          wallDuration.isNegative) {
        locked = true;
      }
    }
    _leftAt = null;
    _leftAtWall = null;
    _notify();
  }

  /// Each sensitive action needs a fresh success. Concurrent requests fail closed.
  Future<bool> authenticate() async {
    if (authenticating || _background || _disposed) return false;
    authenticating = true;
    error = null;
    final epoch = _epoch;
    _notify();
    var success = false;
    try {
      success = await device.authenticate();
    } on Object {
      success = false;
    }
    // Face ID may finish just before the system restores the active scene.
    // Never authorize a mutation or unlock while still behind system UI.
    if (success && _inactive && !_background && !_disposed) {
      await (_resumption ??= Completer<void>()).future;
    }
    success = success && !_disposed && !_background && epoch == _epoch;
    authenticating = false;
    if (!success) {
      error =
          'Authentication was not completed. Try again with Face ID, Touch ID, or your device passcode.';
    }
    _notify();
    return success;
  }

  Future<void> unlock() async {
    if (await authenticate()) {
      locked = false;
      _leftAt = null;
      _leftAtWall = null;
      _notify();
    }
  }

  Future<bool> setEnabled(bool value) async {
    if (!await authenticate()) return false;
    final current = await _settings.get();
    await _settings.update(
      retentionPolicy: current.retentionPolicy,
      biometricLockEnabled: value,
      lockDelay: current.lockDelay,
    );
    settings = await _settings.get();
    locked = false;
    _notify();
    return true;
  }

  Future<void> setDelay(AppLockDelay delay) async {
    final current = await _settings.get();
    await _settings.update(
      retentionPolicy: current.retentionPolicy,
      biometricLockEnabled: current.biometricLockEnabled,
      lockDelay: delay,
    );
    settings = await _settings.get();
    _notify();
  }

  Future<void> finishOnboarding() async {
    final current = await _settings.get();
    await _settings.update(
      retentionPolicy: current.retentionPolicy,
      biometricLockEnabled: current.biometricLockEnabled,
      lockDelay: current.lockDelay,
      onboardingComplete: true,
    );
    settings = await _settings.get();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _resumption?.complete();
    _resumption = null;
    super.dispose();
  }
}

extension on Stopwatch {
  Duration elapsedDuration() => elapsed;
}
