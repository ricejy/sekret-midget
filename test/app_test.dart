import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/app.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';

void main() {
  testWidgets('user asks a question and sees the answer with its evidence', (
    tester,
  ) async {
    await tester.pumpWidget(const SekretMidgetApp());

    expect(
      find.text('Northstar Workshop Employment Agreement'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byType(TextField),
      'How much notice is required to end employment?',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
    await tester.pumpAndSettle();

    expect(
      find.text("Either party must give at least 30 days' written notice."),
      findsOneWidget,
    );
    expect(find.text('12. Termination · Page 8'), findsOneWidget);
    expect(find.textContaining("30 days' written notice"), findsWidgets);
  });

  testWidgets(
    'an ineligible device explains that on-device answers are unavailable',
    (tester) async {
      await tester.pumpWidget(
        const SekretMidgetApp(modelAvailability: DeviceNotEligible()),
      );

      expect(
        find.text('This device cannot run Apple Intelligence.'),
        findsOneWidget,
      );
      expect(
        find.text('On-device answers require an eligible iPhone.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Ask document'), findsNothing);
    },
  );

  testWidgets('disabled Apple Intelligence offers a Settings action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SekretMidgetApp(modelAvailability: AppleIntelligenceNotEnabled()),
    );

    expect(find.text('Apple Intelligence is turned off.'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Open Settings'),
      findsOneWidget,
    );
  });

  testWidgets('model assets that are not ready offer a retry', (tester) async {
    await tester.pumpWidget(
      const SekretMidgetApp(modelAvailability: ModelNotReady()),
    );

    expect(
      find.text('The on-device model is still getting ready.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Check again'), findsOneWidget);
  });

  testWidgets('user sees the fixed response when evidence is insufficient', (
    tester,
  ) async {
    await tester.pumpWidget(const SekretMidgetApp());

    await tester.enterText(
      find.byType(TextField),
      'Does termination happen immediately when fraud is alleged?',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Ask document'));
    await tester.pumpAndSettle();

    expect(
      find.text('I couldn’t find enough evidence in this document.'),
      findsOneWidget,
    );
    expect(find.text('GROUNDED ANSWER'), findsNothing);
  });
}
