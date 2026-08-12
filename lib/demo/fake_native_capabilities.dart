import '../core/platform/embedder.dart';
import '../core/platform/llm_backend.dart';
import '../core/platform/ocr_engine.dart';
import '../core/platform/token_counter.dart';
import '../core/question/document_question_service.dart';

final class FakeEmbedder implements Embedder {
  const FakeEmbedder();

  @override
  Future<List<double>> embed(String text) async {
    final normalized = text.toLowerCase();
    return [
      _mentionsAny(normalized, const [
        'notice',
        'termination',
        'end employment',
      ]),
      _mentionsAny(normalized, const ['salary', 'compensation', 'pay']),
      _mentionsAny(normalized, const ['leave', 'holiday', 'vacation']),
    ];
  }

  double _mentionsAny(String text, List<String> terms) {
    return terms.any(text.contains) ? 1 : 0;
  }
}

final class FakeLlmBackend implements LlmBackend {
  const FakeLlmBackend({this.modelAvailability = const Available()});

  final LlmAvailability modelAvailability;

  @override
  Future<LlmAvailability> availability() async => modelAvailability;

  @override
  Future<String> generate({
    required String question,
    required String evidence,
  }) async {
    if (evidence.contains("30 days' written notice") &&
        !question.toLowerCase().contains('fraud')) {
      return "Either party must give at least 30 days' written notice.";
    }
    return insufficientEvidenceMessage;
  }
}

final class FakeOcrEngine implements OcrEngine {
  const FakeOcrEngine();

  @override
  Future<String> recognizeText(List<int> imageBytes) async {
    return 'Fictional recognized document text.';
  }
}

final class FakeTokenCounter implements TokenCounter {
  const FakeTokenCounter();

  @override
  Future<int> countTokens(String text) async {
    return text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
  }
}
