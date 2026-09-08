import 'package:integration_test/integration_test.dart';
import '../test/chat_screen_test.dart' as scenarios;

/// Fictional data and deterministic model only; never opens the user's vault.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.registerChatScreenTests(physicalDevice: true);
}
