import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/grounded_chat_engine_test.dart' as scenarios;

/// Runs the same deterministic multi-source, budget and provenance scenarios
/// on the target device's Dart/native-SQLite runtime. Uses no personal data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.registerGroundedChatTests(
    testCase: (name, body) {
      testWidgets(name, (tester) async {
        await tester.runAsync(body);
      });
    },
  );
}
