import 'package:integration_test/integration_test.dart';
import '../test/settings_app_test.dart' as scenarios;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // In-memory data and deterministic authentication; never opens the real vault.
  // Actual Face ID/passcode and native snapshots need the separate manual gate.
  scenarios.main();
}
