enum EmbeddingFailureCode {
  unavailable,
  invalidInput,
  vectorUnavailable,
  dimensionMismatch,
  bridgeFailure,
}

final class EmbeddingException implements Exception {
  const EmbeddingException(this.code, this.message);

  final EmbeddingFailureCode code;
  final String message;

  @override
  String toString() => 'EmbeddingException(${code.name}): $message';
}

sealed class EmbeddingModelStatus {
  const EmbeddingModelStatus();
}

final class EmbeddingModelAvailable extends EmbeddingModelStatus {
  const EmbeddingModelAvailable({
    required this.implementation,
    required this.language,
    required this.dimensions,
    required this.revision,
  });

  final String implementation;
  final String language;
  final int dimensions;
  final int revision;
}

final class EmbeddingModelUnavailable extends EmbeddingModelStatus {
  const EmbeddingModelUnavailable({
    required this.implementation,
    required this.language,
    required this.reason,
  });

  final String implementation;
  final String language;
  final String reason;
}

final class EmbeddingModelUnreported extends EmbeddingModelStatus {
  const EmbeddingModelUnreported();
}

abstract interface class EmbeddingCapabilityProbe {
  Future<EmbeddingModelStatus> embeddingModelStatus();
}

abstract interface class Embedder {
  Future<List<double>> embed(String text);
}
