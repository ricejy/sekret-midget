import 'package:integration_test/integration_test.dart';
import '../test/knowledge_screen_test.dart' as scenarios;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.registerKnowledgeScreenTests(physicalDevice: true);
}
