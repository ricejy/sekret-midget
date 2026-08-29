import 'dart:async';

import 'package:flutter/services.dart';

import 'llm_backend.dart';
import 'token_counter.dart';

final class AppleFoundationModels
    implements
        LlmBackend,
        LlmSettingsController,
        TokenCounter,
        ModelContextProbe {
  AppleFoundationModels({MethodChannel? channel, Stream<Object?>? events})
    : _channel = channel ?? const MethodChannel(_methodChannelName),
      _events =
          events ??
          const EventChannel(_eventChannelName).receiveBroadcastStream();

  static const _methodChannelName =
      'com.ricejy.sekret_midget/foundation_models';
  static const _eventChannelName =
      'com.ricejy.sekret_midget/foundation_models_stream';
  static var _requestSequence = 0;

  final MethodChannel _channel;
  final Stream<Object?> _events;

  @override
  Future<LlmAvailability> availability() async {
    try {
      final payload = await _channel.invokeMapMethod<Object?, Object?>(
        'availability',
      );
      return switch (payload?['status']) {
        'available' => const Available(),
        'apple_intelligence_not_enabled' => const AppleIntelligenceNotEnabled(),
        'model_not_ready' => const ModelNotReady(),
        _ => const DeviceNotEligible(),
      };
    } on MissingPluginException {
      return const DeviceNotEligible();
    } on PlatformException {
      return const ModelNotReady();
    }
  }

  @override
  Future<int> contextWindowSize() async {
    final value = await _invokePositiveInt('contextSize');
    return value;
  }

  @override
  Future<int> countTokens(String text) async {
    try {
      return await _count(text, kind: 'prompt');
    } on LlmException catch (error) {
      if (error.code != LlmFailureCode.unavailable) {
        rethrow;
      }
      // Import remains available while Apple Intelligence is disabled. Exact
      // model counts are still required below when assembling a generation
      // context, once the model is available.
      return RegExp(r'\S+').allMatches(text).length;
    }
  }

  @override
  Future<int> countInstructionTokens(String instructions) =>
      _count(instructions, kind: 'instructions');

  @override
  Future<int> countPromptTokens(String prompt) =>
      _count(prompt, kind: 'prompt');

  Future<int> _count(String text, {required String kind}) async {
    if (text.isEmpty) {
      return 0;
    }
    try {
      return await _invokePositiveInt('countTokens', {
        'text': text,
        'kind': kind,
      });
    } on MissingPluginException {
      throw const LlmException(
        LlmFailureCode.unavailable,
        'The Foundation Models token counter is unavailable.',
      );
    } on PlatformException catch (error) {
      throw LlmException(_failureCode(error.code), _safeMessage(error.code));
    }
  }

  Future<int> _invokePositiveInt(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    final value = await _channel.invokeMethod<Object?>(method, arguments);
    if (value is! int || value <= 0) {
      throw const LlmException(
        LlmFailureCode.streamFailure,
        'The Foundation Models bridge returned invalid model metadata.',
      );
    }
    return value;
  }

  @override
  Stream<String> generate({
    required String question,
    required List<String> evidence,
    required String prompt,
  }) async* {
    if (prompt.trim().isEmpty) {
      throw const LlmException(
        LlmFailureCode.streamFailure,
        'The Foundation Models prompt must not be empty.',
      );
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_requestSequence++}';
    final controller = StreamController<Object?>();
    final subscription = _events.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    try {
      await _channel.invokeMethod<void>('generate', {
        'requestId': requestId,
        'prompt': prompt,
      });
      await for (final event in controller.stream) {
        if (event is! Map) {
          continue;
        }
        final payload = event.cast<Object?, Object?>();
        if (payload['requestId'] != requestId) {
          continue;
        }
        switch (payload['type']) {
          case 'snapshot':
            final text = payload['text'];
            if (text is! String) {
              throw const LlmException(
                LlmFailureCode.streamFailure,
                'The Foundation Models stream returned invalid text.',
              );
            }
            yield text;
          case 'completed':
            return;
          case 'error':
            final code = payload['code'];
            throw LlmException(
              _failureCode(code is String ? code : 'stream_failure'),
              _safeMessage(code is String ? code : 'stream_failure'),
            );
        }
      }
      throw const LlmException(
        LlmFailureCode.streamFailure,
        'The Foundation Models stream ended before completion.',
      );
    } on MissingPluginException {
      throw const LlmException(
        LlmFailureCode.unavailable,
        'The Foundation Models bridge is unavailable.',
      );
    } on PlatformException catch (error) {
      throw LlmException(_failureCode(error.code), _safeMessage(error.code));
    } finally {
      await subscription.cancel();
      await controller.close();
      try {
        await _channel.invokeMethod<void>('cancel', {'requestId': requestId});
      } on Object {
        // Cancellation is best-effort after the stream has already terminated.
      }
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on Object {
      // The availability panel remains useful if Settings cannot be opened.
    }
  }

  Future<void> protectStorage({
    required String directoryPath,
    required String databasePath,
  }) async {
    try {
      await _channel.invokeMethod<void>('protectStorage', {
        'directoryPath': directoryPath,
        'databasePath': databasePath,
      });
    } on Object {
      throw StateError(
        'The private library could not enable iOS file protection.',
      );
    }
  }

  LlmFailureCode _failureCode(String code) => switch (code) {
    'model_unavailable' => LlmFailureCode.unavailable,
    'context_overflow' => LlmFailureCode.contextOverflow,
    'guardrail_violation' => LlmFailureCode.guardrailViolation,
    _ => LlmFailureCode.streamFailure,
  };

  String _safeMessage(String code) => switch (code) {
    'model_unavailable' => 'The on-device model is unavailable.',
    'context_overflow' => 'The request exceeds the on-device context window.',
    'guardrail_violation' =>
      'The on-device model declined this content transformation.',
    _ => 'The on-device generation stream failed.',
  };
}
