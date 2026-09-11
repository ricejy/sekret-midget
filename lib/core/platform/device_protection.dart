import 'package:flutter/services.dart';

/// Device-owned authentication, never an application PIN or encryption key.
abstract interface class DeviceProtection {
  Future<bool> authenticate();
  Future<Map<String, String>> diagnostics();
  Future<void> purgeImportCopies();
}

final class AppleDeviceProtection implements DeviceProtection {
  const AppleDeviceProtection({
    this._channel = const MethodChannel('com.ricejy.sekret_midget/protection'),
  });
  final MethodChannel _channel;

  @override
  Future<void> purgeImportCopies() =>
      _channel.invokeMethod<void>('purgeImportCopies');

  Future<void> discardImportCopy(String path) =>
      _channel.invokeMethod<void>('discardImportCopy', {'path': path});

  @override
  Future<bool> authenticate() async {
    try {
      return await _channel.invokeMethod<bool>('authenticate') == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<Map<String, String>> diagnostics() async {
    try {
      final result = await _channel.invokeMapMethod<String, String>(
        'diagnostics',
      );
      // Deliberate allowlist: never serialize errors, paths, identifiers or data.
      return {
        for (final key in ['version', 'build', 'os', 'authentication'])
          if (result?[key] != null) key: result![key]!,
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }
}
