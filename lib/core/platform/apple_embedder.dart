import 'package:flutter/services.dart';

import 'embedder.dart';

final class AppleEmbedder implements Embedder, EmbeddingCapabilityProbe {
  AppleEmbedder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.ricejy.sekret_midget/embedding';

  final MethodChannel _channel;
  EmbeddingModelStatus? _cachedStatus;

  @override
  Future<EmbeddingModelStatus> embeddingModelStatus() async {
    if (_cachedStatus case final status?) {
      return status;
    }
    try {
      final payload = await _channel.invokeMapMethod<Object?, Object?>(
        'availability',
      );
      if (payload == null) {
        return _cacheUnavailable('The native bridge returned no capability.');
      }
      final available = payload['available'];
      final language = payload['language'];
      if (available is! bool || language is! String) {
        return _cacheUnavailable('The native capability was malformed.');
      }
      if (!available) {
        final reason = payload['reason'];
        return _cacheUnavailable(
          reason is String ? reason : 'Sentence embeddings are unavailable.',
          language: language,
        );
      }
      final dimensions = payload['dimensions'];
      final revision = payload['revision'];
      if (dimensions is! int || dimensions <= 0 || revision is! int) {
        return _cacheUnavailable(
          'The native embedding metadata was invalid.',
          language: language,
        );
      }
      final status = EmbeddingModelAvailable(
        implementation: 'Apple Natural Language',
        language: language,
        dimensions: dimensions,
        revision: revision,
      );
      _cachedStatus = status;
      return status;
    } on MissingPluginException {
      return _cacheUnavailable('The Apple embedding bridge is unavailable.');
    } on PlatformException catch (error) {
      return _cacheUnavailable(_safeMessage(error));
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    if (text.trim().isEmpty) {
      throw const EmbeddingException(
        EmbeddingFailureCode.invalidInput,
        'Text must not be empty.',
      );
    }
    final status = await embeddingModelStatus();
    if (status is! EmbeddingModelAvailable) {
      throw const EmbeddingException(
        EmbeddingFailureCode.unavailable,
        'Apple sentence embeddings are unavailable.',
      );
    }
    try {
      final payload = await _channel.invokeListMethod<Object?>('embed', {
        'text': text,
      });
      if (payload == null || payload.any((value) => value is! num)) {
        throw const EmbeddingException(
          EmbeddingFailureCode.bridgeFailure,
          'The native bridge returned an invalid vector.',
        );
      }
      final vector = payload
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
      if (vector.length != status.dimensions) {
        throw EmbeddingException(
          EmbeddingFailureCode.dimensionMismatch,
          'Expected ${status.dimensions} dimensions but received ${vector.length}.',
        );
      }
      return vector;
    } on MissingPluginException {
      throw const EmbeddingException(
        EmbeddingFailureCode.bridgeFailure,
        'The Apple embedding bridge is unavailable.',
      );
    } on PlatformException catch (error) {
      throw EmbeddingException(_failureCode(error.code), _safeMessage(error));
    }
  }

  EmbeddingModelUnavailable _cacheUnavailable(
    String reason, {
    String language = 'en',
  }) {
    final status = EmbeddingModelUnavailable(
      implementation: 'Apple Natural Language',
      language: language,
      reason: reason,
    );
    _cachedStatus = status;
    return status;
  }

  EmbeddingFailureCode _failureCode(String code) => switch (code) {
    'embedding_unavailable' => EmbeddingFailureCode.unavailable,
    'invalid_input' => EmbeddingFailureCode.invalidInput,
    'vector_unavailable' => EmbeddingFailureCode.vectorUnavailable,
    'dimension_mismatch' => EmbeddingFailureCode.dimensionMismatch,
    _ => EmbeddingFailureCode.bridgeFailure,
  };

  String _safeMessage(PlatformException error) => switch (error.code) {
    'embedding_unavailable' =>
      'Apple sentence embeddings are unavailable for English.',
    'invalid_input' => 'Text must not be empty.',
    'vector_unavailable' => 'Apple could not embed this text.',
    'dimension_mismatch' => 'Apple returned an unexpected vector shape.',
    _ => 'The Apple embedding bridge failed.',
  };
}
