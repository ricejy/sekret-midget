abstract interface class TokenCounter {
  Future<int> countTokens(String text);
}

abstract interface class ModelContextProbe {
  Future<int> contextWindowSize();

  Future<int> countInstructionTokens(String instructions);

  Future<int> countPromptTokens(String prompt);
}
