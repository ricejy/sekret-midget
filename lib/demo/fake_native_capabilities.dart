import '../core/platform/embedder.dart';
import '../core/platform/llm_backend.dart';
import '../core/platform/ocr_engine.dart';
import '../core/platform/token_counter.dart';
import '../core/question/document_question_service.dart';

final class FakeEmbedder implements Embedder, EmbeddingCapabilityProbe {
  const FakeEmbedder();

  @override
  Future<EmbeddingModelStatus> embeddingModelStatus() async {
    return const EmbeddingModelAvailable(
      implementation: 'Deterministic fake',
      language: 'en',
      dimensions: 5,
      revision: 1,
    );
  }

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
      _mentionsAny(normalized, const [
        'incident',
        'accident',
        'report',
        'disclose',
        'disclosed',
        'safety officer',
      ]),
      _mentionsAny(normalized, const ['equipment', 'protective', 'property']),
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
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) async* {
    final normalizedQuestion = question.toLowerCase();
    final terminationIndex = evidence.indexWhere(
      (passage) => passage.contains("30 days' written notice"),
    );
    if (terminationIndex >= 0 &&
        !normalizedQuestion.contains('fraud') &&
        (normalizedQuestion.contains('termination') ||
            normalizedQuestion.contains('end employment') ||
            normalizedQuestion.contains('notice'))) {
      yield "Either party must give at least 30 days' written notice.";
      return;
    }
    final fictionalPdfNoticeIndex = evidence.indexWhere(
      (passage) => passage.contains('forty-five calendar days'),
    );
    if (fictionalPdfNoticeIndex >= 0 &&
        (normalizedQuestion.contains('termination') ||
            normalizedQuestion.contains('end employment') ||
            normalizedQuestion.contains('notice') ||
            normalizedQuestion.contains('advance warning'))) {
      yield 'Either fictional party must provide forty-five calendar days of written notice.';
      return;
    }
    final incidentIndex = evidence.indexWhere(
      (passage) => passage.contains('within 14 calendar days'),
    );
    if (incidentIndex >= 0 &&
        (normalizedQuestion.contains('incident') ||
            normalizedQuestion.contains('accident') ||
            normalizedQuestion.contains('disclos'))) {
      yield 'An employee must report an incident within 14 calendar days.';
      return;
    }
    final equipmentReturnIndex = evidence.indexWhere(
      (passage) => passage.contains('within seven calendar days'),
    );
    if (equipmentReturnIndex >= 0 &&
        normalizedQuestion.contains('equipment') &&
        (normalizedQuestion.contains('when') ||
            normalizedQuestion.contains('how soon') ||
            normalizedQuestion.contains('deadline'))) {
      yield 'The fictional employee must return the equipment within seven calendar days after the final workday.';
      return;
    }
    yield insufficientEvidenceMessage;
  }
}

final class FakeOcrEngine implements OcrEngine {
  const FakeOcrEngine();

  @override
  Future<OcrRecognition> recognize({
    required OcrImageInput image,
    required bool Function() isCancelled,
  }) async {
    return const OcrRecognition(
      text: 'Fictional recognized document text.',
      confidence: 0.99,
    );
  }
}

final class FakeTokenCounter implements TokenCounter, ModelContextProbe {
  const FakeTokenCounter();

  @override
  Future<int> countTokens(String text) async {
    return text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
  }

  @override
  Future<int> contextWindowSize() async => 4096;

  @override
  Future<int> countInstructionTokens(String instructions) =>
      countTokens(instructions);

  @override
  Future<int> countPromptTokens(String prompt) => countTokens(prompt);
}
