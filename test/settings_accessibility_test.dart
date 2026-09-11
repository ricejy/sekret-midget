import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/chat/chat_workspace.dart';
import 'package:sekret_midget/core/settings/app_protection.dart';
import 'package:sekret_midget/core/storage/local_data_vault.dart';
import 'package:sekret_midget/demo/fake_native_capabilities.dart';
import 'package:sekret_midget/ui/settings/settings_screen.dart';
import 'package:sekret_midget/ui/settings/onboarding_screen.dart';
import 'app_protection_test.dart' show FakeDeviceProtection;
import 'settings_app_test.dart' show settleSettings;

void main() {
  testWidgets(
    'Settings and onboarding support narrow screens, dark appearance, and large type',
    (tester) async {
      final vault = await openLocalDataVault(databasePath: ':memory:');
      final workspace = await ChatWorkspace.open(vault);
      final protection = AppProtection(vault.settings, FakeDeviceProtection());
      await protection.initialize();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const screenshots = bool.fromEnvironment('WRITE_SETTINGS_SCREENSHOTS');
      if (screenshots && Platform.isMacOS) {
        await tester.runAsync(() async {
          for (final family in [
            'CupertinoSystemText',
            'CupertinoSystemDisplay',
          ]) {
            await (FontLoader(family)..addFont(
                  File(
                    '/System/Library/Fonts/SFNS.ttf',
                  ).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          }
          await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
                rootBundle.load(
                  'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                ),
              ))
              .load();
        });
      }
      final screen = GlobalKey();
      Future<void> capture(String name) async {
        if (!screenshots) return;
        await tester.runAsync(() async {
          final image =
              await (screen.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/private/tmp/sekret-settings-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> mount({
        double scale = 1,
        bool dark = false,
        bool onboarding = false,
      }) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: screen,
            child: CupertinoApp(
              debugShowCheckedModeBanner: false,
              theme: CupertinoThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: onboarding
                  ? OnboardingScreen(
                      protection: protection,
                      model: const FakeLlmBackend(),
                      openSystemSettings: () async {},
                    )
                  : SettingsScreen(
                      vault: vault,
                      workspace: workspace,
                      protection: protection,
                      model: const FakeLlmBackend(),
                      openSystemSettings: () async {},
                      deleteData: (_) async {},
                    ),
            ),
          ),
        );
        await settleSettings(tester);
      }

      await mount();
      await capture('light');
      await tester.scrollUntilVisible(find.text('App lock'), 200);
      await settleSettings(tester);
      await capture('lock');
      await mount(scale: 2, dark: true);
      await tester.scrollUntilVisible(find.text('Lock delay'), 200);
      await settleSettings(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Lock delay').hitTestable(), findsOneWidget);
      await capture('large-dark');
      await mount(onboarding: true);
      await capture('onboarding');
      await mount(scale: 2, dark: true, onboarding: true);
      await tester.scrollUntilVisible(find.text('Continue to Sekret'), 300);
      await settleSettings(tester);
      expect(find.text('Continue to Sekret').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      protection.dispose();
      await workspace.dispose();
      await vault.close();
    },
  );
}
