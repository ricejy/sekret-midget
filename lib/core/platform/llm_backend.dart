abstract interface class LlmBackend {
  Future<LlmAvailability> availability();

  Future<GeneratedAnswer> generate({
    required String question,
    required List<String> evidence,
  });
}

final class GeneratedAnswer {
  const GeneratedAnswer({required this.text, this.supportingEvidenceIndex});

  final String text;
  final int? supportingEvidenceIndex;
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
