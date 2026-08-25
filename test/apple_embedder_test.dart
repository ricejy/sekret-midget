import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/platform/apple_embedder.dart';
import 'package:sekret_midget/core/platform/embedder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.ricejy.sekret_midget/embedding');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reports Apple availability and runtime vector metadata', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'availability');
          return <String, Object>{
            'available': true,
            'language': 'en',
            'dimensions': 3,
            'revision': 7,
          };
        });

    final status = await AppleEmbedder(channel: channel).embeddingModelStatus();

    expect(
      status,
      isA<EmbeddingModelAvailable>()
          .having((value) => value.dimensions, 'dimensions', 3)
          .having((value) => value.revision, 'revision', 7)
          .having((value) => value.language, 'language', 'en'),
    );
  });

  test('returns a native sentence vector with the reported shape', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'availability') {
            return <String, Object>{
              'available': true,
              'language': 'en',
              'dimensions': 3,
              'revision': 7,
            };
          }
          expect(call.method, 'embed');
          expect(call.arguments, <String, Object>{'text': 'A sentence.'});
          return <double>[0.25, -0.5, 1];
        });

    final vector = await AppleEmbedder(channel: channel).embed('A sentence.');

    expect(vector, <double>[0.25, -0.5, 1]);
  });

  test('maps native failures to portable embedding error codes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'availability') {
            return <String, Object>{
              'available': true,
              'language': 'en',
              'dimensions': 3,
              'revision': 7,
            };
          }
          throw PlatformException(
            code: 'vector_unavailable',
            message: 'PRIVATE NATIVE DETAIL',
          );
        });

    expect(
      () => AppleEmbedder(channel: channel).embed('Private document text'),
      throwsA(
        isA<EmbeddingException>()
            .having(
              (error) => error.code,
              'code',
              EmbeddingFailureCode.vectorUnavailable,
            )
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('PRIVATE')),
            ),
      ),
    );
  });

  test('rejects a native vector with an unexpected dimension', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'availability') {
            return <String, Object>{
              'available': true,
              'language': 'en',
              'dimensions': 3,
              'revision': 7,
            };
          }
          return <double>[1, 2];
        });

    expect(
      () => AppleEmbedder(channel: channel).embed('A sentence.'),
      throwsA(
        isA<EmbeddingException>().having(
          (error) => error.code,
          'code',
          EmbeddingFailureCode.dimensionMismatch,
        ),
      ),
    );
  });
}
