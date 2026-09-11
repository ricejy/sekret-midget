import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/platform/device_protection.dart';
import 'package:sekret_midget/core/settings/app_protection.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';

class FakeDeviceProtection implements DeviceProtection {
  bool success = true;
  int requests = 0;
  Completer<bool>? pending;
  int purges = 0;
  @override
  Future<void> purgeImportCopies() async {
    purges++;
  }

  @override
  Future<bool> authenticate() async {
    requests++;
    return pending == null ? success : pending!.future;
  }

  @override
  Future<Map<String, String>> diagnostics() async => const {
    'version': '1.0',
    'build': '1',
    'os': 'iOS fixture',
    'authentication': 'Face ID or device passcode',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalDataVault vault;
  late FakeDeviceProtection device;
  late AppProtection protection;
  var elapsed = Duration.zero;
  setUp(() async {
    vault = await openLocalDataVault(databasePath: ':memory:');
    device = FakeDeviceProtection();
    elapsed = Duration.zero;
    protection = AppProtection(vault.settings, device, elapsed: () => elapsed);
    await protection.initialize();
  });
  tearDown(() async {
    protection.dispose();
    await vault.close();
  });

  test(
    'device sleep counts toward delay and backwards clock changes lock',
    () async {
      var wall = DateTime.utc(2026, 9, 10);
      final sleeping = AppProtection(
        vault.settings,
        device,
        elapsed: () => Duration.zero,
        wallClock: () => wall,
      );
      await sleeping.initialize();
      await sleeping.setEnabled(true);
      await sleeping.setDelay(AppLockDelay.oneMinute);
      sleeping.inactive();
      sleeping.background();
      wall = wall.add(const Duration(minutes: 1));
      sleeping.resumed();
      expect(sleeping.locked, isTrue);
      await sleeping.unlock();
      sleeping.inactive();
      wall = wall.subtract(const Duration(seconds: 1));
      sleeping.resumed();
      expect(sleeping.locked, isTrue);
      sleeping.dispose();
    },
  );

  test('onboarding is persisted without changing retention or lock', () async {
    expect(protection.settings!.onboardingComplete, isFalse);
    await protection.setEnabled(true);
    await protection.setDelay(AppLockDelay.fifteenMinutes);
    await protection.finishOnboarding();
    final stored = await vault.settings.get();
    expect(stored.onboardingComplete, isTrue);
    expect(stored.biometricLockEnabled, isTrue);
    expect(stored.lockDelay, AppLockDelay.fifteenMinutes);
    expect(stored.retentionPolicy, RetentionPolicy.manual);
  });

  test(
    'cancelled enable/disable never changes persistent protection',
    () async {
      device.success = false;
      expect(await protection.setEnabled(true), isFalse);
      expect((await vault.settings.get()).biometricLockEnabled, isFalse);
      device.success = true;
      await protection.setEnabled(true);
      device.success = false;
      expect(await protection.setEnabled(false), isFalse);
      expect((await vault.settings.get()).biometricLockEnabled, isTrue);
    },
  );

  for (final delay in AppLockDelay.values) {
    test(
      '${delay.name}: exact delay boundary and cold launch require auth',
      () async {
        await protection.setEnabled(true);
        await protection.setDelay(delay);
        final reopened = AppProtection(vault.settings, device);
        await reopened.initialize();
        expect(reopened.locked, isTrue);
        reopened.dispose();
        final limit = switch (delay) {
          AppLockDelay.immediate => Duration.zero,
          AppLockDelay.oneMinute => const Duration(minutes: 1),
          AppLockDelay.fifteenMinutes => const Duration(minutes: 15),
        };
        if (limit > Duration.zero) {
          protection.inactive();
          protection.background();
          elapsed += limit - const Duration(milliseconds: 1);
          protection.resumed();
          expect(protection.locked, isFalse);
        }
        protection.inactive();
        protection.background();
        elapsed += limit;
        protection.resumed();
        expect(protection.locked, isTrue);
        device.success = false;
        await protection.unlock();
        expect(protection.locked, isTrue);
        device.success = true;
        await protection.unlock();
        expect(protection.locked, isFalse);
      },
    );
  }

  test(
    'Face ID inactive/resume does not relock or authorize before active',
    () async {
      await protection.setEnabled(true);
      protection.inactive();
      protection.resumed();
      expect(protection.locked, isTrue);
      device.pending = Completer<bool>();
      final unlock = protection.unlock();
      protection.inactive();
      device.pending!.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(protection.locked, isTrue);
      protection.resumed();
      await unlock;
      expect(protection.locked, isFalse);
    },
  );

  test('backgrounded and overlapping authentication fails closed', () async {
    await protection.setEnabled(true);
    protection.inactive();
    protection.resumed();
    device.pending = Completer<bool>();
    final unlock = protection.unlock();
    expect(await protection.authenticate(), isFalse);
    protection.inactive();
    protection.background();
    protection.resumed();
    device.pending!.complete(true);
    await unlock;
    expect(protection.locked, isTrue);
  });

  test(
    'device bridge fails closed and diagnostics allowlist excludes content',
    () async {
      const channel = MethodChannel('test/protection');
      const bridge = AppleDeviceProtection(channel: channel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'authenticate') {
          throw PlatformException(code: 'cancelled');
        }
        return {
          'version': '1',
          'os': 'iOS',
          'prompt': 'private',
          'filename': 'private.pdf',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await bridge.authenticate(), isFalse);
      expect(await bridge.diagnostics(), {'version': '1', 'os': 'iOS'});
      messenger.setMockMethodCallHandler(channel, null);
      expect(await bridge.authenticate(), isFalse);
    },
  );
}
