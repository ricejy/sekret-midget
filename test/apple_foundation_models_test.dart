import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/platform/apple_foundation_models.dart';
import 'package:sekret_midget/core/platform/llm_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'com.ricejy.sekret_midget/foundation_models-test',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('maps all production availability states', () async {
    for (final (status, matcher) in [
      ('available', isA<Available>()),
      ('device_not_eligible', isA<DeviceNotEligible>()),
      ('apple_intelligence_not_enabled', isA<AppleIntelligenceNotEnabled>()),
      ('model_not_ready', isA<ModelNotReady>()),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => {'status': status});

      final availability = await AppleFoundationModels(
        channel: channel,
        events: const Stream.empty(),
      ).availability();

      expect(availability, matcher);
    }
  });

  test('uses native context size and distinct exact token inputs', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'contextSize' => 4096,
            'countTokens' => 27,
            _ => null,
          };
        });
    final models = AppleFoundationModels(
      channel: channel,
      events: const Stream.empty(),
    );

    expect(await models.contextWindowSize(), 4096);
    expect(await models.countInstructionTokens('instructions'), 27);
    expect(await models.countPromptTokens('prompt'), 27);
    expect(calls[1].arguments, {
      'text': 'instructions',
      'kind': 'instructions',
    });
    expect(calls[2].arguments, {'text': 'prompt', 'kind': 'prompt'});
  });

  test(
    'keeps import chunking available while the model is unavailable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
          (_) async => throw PlatformException(
              code: 'model_unavailable',
              message: 'PRIVATE NATIVE DETAIL',
            ),
          );
      final models = AppleFoundationModels(
        channel: channel,
        events: const Stream.empty(),
      );

      expect(await models.countTokens('three fictional words'), 3);
      expect(
        models.countPromptTokens('three fictional words'),
        throwsA(
          isA<LlmException>().having(
            (error) => error.code,
            'code',
            LlmFailureCode.unavailable,
          ),
        ),
      );
    },
  );

  test('streams cumulative plain-string snapshots to completion', () async {
    final events = StreamController<Object?>.broadcast();
    addTearDown(events.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'generate') {
            final requestId = (call.arguments as Map)['requestId'] as String;
            scheduleMicrotask(() {
              events.add({
                'requestId': requestId,
                'type': 'snapshot',
                'text': 'The fictional',
              });
              events.add({
                'requestId': requestId,
                'type': 'snapshot',
                'text': 'The fictional deadline is fourteen days.',
              });
              events.add({'requestId': requestId, 'type': 'completed'});
            });
          }
          return null;
        });
    final models = AppleFoundationModels(
      channel: channel,
      events: events.stream,
    );

    final snapshots = await models
        .generate(
          question: 'What is the deadline?',
          evidence: const ['The fictional deadline is fourteen days.'],
          prompt: '<document_excerpt>fictional</document_excerpt>',
        )
        .toList();

    expect(snapshots, [
      'The fictional',
      'The fictional deadline is fourteen days.',
    ]);
  });

  test('maps sanitized native generation failures', () async {
    final events = StreamController<Object?>.broadcast();
    addTearDown(events.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'generate') {
            final requestId = (call.arguments as Map)['requestId'] as String;
            scheduleMicrotask(() {
              events.add({
                'requestId': requestId,
                'type': 'error',
                'code': 'guardrail_violation',
                'details': 'PRIVATE NATIVE DETAIL',
              });
            });
          }
          return null;
        });
    final models = AppleFoundationModels(
      channel: channel,
      events: events.stream,
    );

    expect(
      () => models
          .generate(
            question: 'Question',
            evidence: const ['Private evidence'],
            prompt: '<document_excerpt>Private evidence</document_excerpt>',
          )
          .drain<void>(),
      throwsA(
        isA<LlmException>()
            .having(
              (error) => error.code,
              'code',
              LlmFailureCode.guardrailViolation,
            )
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('PRIVATE')),
            ),
      ),
    );
  });

  test('guardrail-v1 prompt is frozen and contains only supplied inputs', () {
    final prompt = buildGuardrailV1Prompt(
      question: 'When is payment due?',
      evidence: const ['PAYMENT\nPayment is due in ten days.'],
    );

    expect(guardrailPromptVersion, 'guardrail-v1');
    expect(guardrailV1Instructions, contains('only the supplied document'));
    expect(prompt, startsWith('<document_excerpt>'));
    expect(prompt, contains('Payment is due in ten days.'));
    expect(prompt, endsWith('</question>'));
  });
}
