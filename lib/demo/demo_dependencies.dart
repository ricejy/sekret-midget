import '../core/question/document_question_service.dart';
import '../core/platform/llm_backend.dart';
import 'fake_native_capabilities.dart';

DocumentQuestionService createDemoDocumentQuestionService({
  LlmAvailability modelAvailability = const Available(),
}) {
  return DocumentQuestionService(
    const FakeEmbedder(),
    FakeLlmBackend(modelAvailability: modelAvailability),
  );
}
