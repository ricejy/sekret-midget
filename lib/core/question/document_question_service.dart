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

sealed class DocumentQuestionUpdate {
  const DocumentQuestionUpdate();
}

final class AnswerTextUpdate extends DocumentQuestionUpdate {
  const AnswerTextUpdate(this.text);

  final String text;
}

final class AnswerCompleted extends DocumentQuestionUpdate {
  const AnswerCompleted(this.outcome);

  final DocumentQuestionOutcome outcome;
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

final class RetrievalUnavailable extends DocumentQuestionOutcome {
  const RetrievalUnavailable(this.message);

  final String message;
}

enum AnswerFailureKind {
  modelUnavailable,
  contextOverflow,
  guardrailViolation,
  streamFailure,
}

final class AnswerFailure extends DocumentQuestionOutcome {
  const AnswerFailure({required this.kind, required this.message});

  final AnswerFailureKind kind;
  final String message;
}

final class DocumentQuestionService {
  const DocumentQuestionService(this._embedder, this._llmBackend);

  final Embedder _embedder;
  final LlmBackend _llmBackend;

  Future<DocumentQuestionOutcome> ask({
    required Document document,
    required String question,
  }) async {
    try {
      return await _askWithEmbeddings(document: document, question: question);
    } on EmbeddingException catch (error) {
      return RetrievalUnavailable(error.message);
    }
  }

  Future<DocumentQuestionOutcome> _askWithEmbeddings({
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

    final prompt = buildGuardrailV1Prompt(
      question: question,
      evidence: [bestChunk.text],
    );
    String? generatedText;
    try {
      await for (final snapshot in _llmBackend.generate(
        question: question,
        evidence: [bestChunk.text],
        prompt: prompt,
      )) {
        generatedText = snapshot;
      }
    } on LlmException catch (error) {
      return answerFailureFor(error.code);
    }
    final answer = generatedText?.trim();
    if (answer == null || answer.isEmpty) {
      return const AnswerFailure(
        kind: AnswerFailureKind.streamFailure,
        message: 'The on-device answer stopped before completion. Try again.',
      );
    }
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

AnswerFailure answerFailureFor(LlmFailureCode code) => switch (code) {
  LlmFailureCode.unavailable => const AnswerFailure(
    kind: AnswerFailureKind.modelUnavailable,
    message:
        'The on-device model became unavailable. Check its status and try again.',
  ),
  LlmFailureCode.contextOverflow => const AnswerFailure(
    kind: AnswerFailureKind.contextOverflow,
    message:
        'The evidence exceeds the on-device model context. Ask a narrower question.',
  ),
  LlmFailureCode.guardrailViolation => const AnswerFailure(
    kind: AnswerFailureKind.guardrailViolation,
    message:
        'The on-device model could not transform this document content. Try a narrower factual question.',
  ),
  LlmFailureCode.streamFailure => const AnswerFailure(
    kind: AnswerFailureKind.streamFailure,
    message: 'The on-device answer stopped before completion. Try again.',
  ),
};

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
