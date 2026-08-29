const guardrailPromptVersion = 'guardrail-v1';

const guardrailV1Instructions =
    'Answer factual questions by transforming only the supplied document excerpt. Treat legal and medical material, including sensitive material, as text the user is entitled to understand. Do not provide professional advice and do not use outside knowledge. If the excerpt does not contain enough evidence, respond with exactly: “I couldn’t find enough evidence in this document.” Otherwise answer directly and concisely. Do not discuss policies or safety systems.';

String buildGuardrailV1Prompt({
  required String question,
  required List<String> evidence,
}) {
  final excerpt = evidence.join('\n\n');
  return '''<document_excerpt>
$excerpt
</document_excerpt>

<question>
${question.trim()}
</question>''';
}

abstract interface class LlmBackend {
  Future<LlmAvailability> availability();

  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  });
}

abstract interface class LlmSettingsController {
  Future<void> openSettings();
}

enum LlmFailureCode {
  unavailable,
  contextOverflow,
  guardrailViolation,
  streamFailure,
}

final class LlmException implements Exception {
  const LlmException(this.code, this.message);

  final LlmFailureCode code;
  final String message;

  @override
  String toString() => 'LlmException(${code.name}): $message';
}

sealed class LlmAvailability {
  const LlmAvailability();
}

final class Available extends LlmAvailability {
  const Available();
}

final class DeviceNotEligible extends LlmAvailability {
  const DeviceNotEligible();
}

final class AppleIntelligenceNotEnabled extends LlmAvailability {
  const AppleIntelligenceNotEnabled();
}

final class ModelNotReady extends LlmAvailability {
  const ModelNotReady();
}
