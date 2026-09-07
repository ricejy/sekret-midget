import 'dart:async';

import 'package:flutter/services.dart';

import 'llm_backend.dart';
import 'token_counter.dart';

final class AppleFoundationModels
    implements
        LlmBackend,
        GeneralLlmBackend,
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
  }) => _generate(prompt, mode: 'knowledge-base');

  @override
  Stream<String> generateGeneral({required String prompt}) =>
      _generate(prompt, mode: 'general');

  Stream<String> _generate(String prompt, {required String mode}) {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_requestSequence++}';
    late final StreamController<String> controller;
    StreamSubscription<Object?>? subscription;
    var ended = false;
    void fail(String code) {
      if (ended) return;
      ended = true;
      controller.addError(LlmException(_failureCode(code), _safeMessage(code)));
      unawaited(controller.close());
    }

    controller = StreamController<String>(
      onListen: () {
        if (prompt.trim().isEmpty) {
          fail('stream_failure');
          return;
        }
        subscription = _events.listen(
          (event) {
            if (ended) return;
            if (event is! Map) {
              return;
            }
            final payload = event.cast<Object?, Object?>();
            if (payload['requestId'] != requestId) {
              return;
            }
            switch (payload['type']) {
              case 'snapshot':
                final text = payload['text'];
                if (text is! String) {
                  fail('stream_failure');
                  return;
                }
                controller.add(text);
              case 'completed':
                ended = true;
                unawaited(controller.close());
              case 'error':
                final code = payload['code'];
                fail(code is String ? code : 'stream_failure');
            }
          },
          onError: (Object _) => fail('stream_failure'),
          onDone: () => fail('stream_failure'),
        );
        unawaited(
          _channel
              .invokeMethod<void>('generate', {
                'requestId': requestId,
                'prompt': prompt,
                'mode': mode,
              })
              .catchError((Object error) {
                fail(
                  error is PlatformException
                      ? error.code
                      : error is MissingPluginException
                      ? 'model_unavailable'
                      : 'stream_failure',
                );
              }),
        );
      },
      onCancel: () async {
        ended = true;
        try {
          await _channel.invokeMethod<void>('cancel', {'requestId': requestId});
        } on Object {
          // Cancellation is best-effort after the stream has already terminated.
        } finally {
          await subscription?.cancel();
        }
      },
    );
    return controller.stream;
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
    'generation_interrupted' => LlmFailureCode.interrupted,
    'model_unavailable' => LlmFailureCode.unavailable,
    'context_overflow' => LlmFailureCode.contextOverflow,
    'guardrail_violation' => LlmFailureCode.guardrailViolation,
    _ => LlmFailureCode.streamFailure,
  };

  String _safeMessage(String code) => switch (code) {
    'generation_interrupted' => 'The on-device response was interrupted.',
    'model_unavailable' => 'The on-device model is unavailable.',
    'context_overflow' => 'The request exceeds the on-device context window.',
    'guardrail_violation' =>
      'The on-device model declined this content transformation.',
    _ => 'The on-device generation stream failed.',
  };
}
