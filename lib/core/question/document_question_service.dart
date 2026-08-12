import 'dart:math' as math;

import '../document/document.dart';
import '../platform/embedder.dart';
import '../platform/llm_backend.dart';

const insufficientEvidenceMessage =
    'I couldn’t find enough evidence in this document.';

final class Citation {
  const Citation({
    required this.passage,
    required this.page,
    required this.heading,
  });

  final String passage;
  final int page;
  final String heading;
}

sealed class DocumentQuestionOutcome {
  const DocumentQuestionOutcome();
}

final class GroundedAnswer extends DocumentQuestionOutcome {
  const GroundedAnswer({required this.text, required this.citation});

  final String text;
  final Citation citation;
}

final class InsufficientEvidence extends DocumentQuestionOutcome {
  const InsufficientEvidence();

  String get message => insufficientEvidenceMessage;
}

final class DocumentQuestionService {
  const DocumentQuestionService(this._embedder, this._llmBackend);

  final Embedder _embedder;
  final LlmBackend _llmBackend;

  Future<DocumentQuestionOutcome> ask({
    required Document document,
    required String question,
  }) async {
    final questionVector = await _embedder.embed(question);
    DocumentChunk? bestChunk;
    var bestScore = 0.0;

    for (final chunk in document.chunks) {
      final chunkVector = await _embedder.embed(chunk.text);
      final score = _cosineSimilarity(questionVector, chunkVector);
      if (score > bestScore) {
        bestScore = score;
        bestChunk = chunk;
      }
    }

    if (bestChunk == null || bestScore < 0.5) {
      return const InsufficientEvidence();
    }

    final answer = await _llmBackend.generate(
      question: question,
      evidence: bestChunk.text,
    );
    if (answer == insufficientEvidenceMessage) {
      return const InsufficientEvidence();
    }
    return GroundedAnswer(
      text: answer,
      citation: Citation(
        passage: bestChunk.text,
        page: bestChunk.page,
        heading: bestChunk.heading,
      ),
    );
  }
}

double _cosineSimilarity(List<double> left, List<double> right) {
  if (left.length != right.length || left.isEmpty) {
    return 0;
  }

  var dotProduct = 0.0;
  var leftMagnitude = 0.0;
  var rightMagnitude = 0.0;
  for (var index = 0; index < left.length; index += 1) {
    dotProduct += left[index] * right[index];
    leftMagnitude += left[index] * left[index];
    rightMagnitude += right[index] * right[index];
  }

  if (leftMagnitude == 0 || rightMagnitude == 0) {
    return 0;
  }
  return dotProduct / math.sqrt(leftMagnitude * rightMagnitude);
}
