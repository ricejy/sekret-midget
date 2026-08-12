abstract interface class LlmBackend {
  Future<LlmAvailability> availability();

  Future<String> generate({required String question, required String evidence});
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
