import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/platform/apple_vision_ocr.dart';
import 'package:sekret_midget/core/platform/ocr_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ricejy.sekret_midget/vision_ocr');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends an encoded photo and returns text with confidence', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, Object>{
            'text': 'RETURN DEADLINE\nSeven calendar days.',
            'confidence': 0.91,
          };
        });

    final recognition = await AppleVisionOcr().recognize(
      image: OcrImageInput.encoded(Uint8List.fromList(const [1, 2, 3])),
      isCancelled: () => false,
    );

    expect(receivedCall?.method, 'recognize');
    expect(receivedCall?.arguments, {
      'bytes': Uint8List.fromList(const [1, 2, 3]),
      'format': 'encoded',
    });
    expect(recognition.text, contains('Seven calendar days'));
    expect(recognition.confidence, 0.91);
  });

  test('sends rendered PDF pixels with dimensions', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, Object>{
            'text': 'Readable page text',
            'confidence': 1,
          };
        });

    await AppleVisionOcr().recognize(
      image: OcrImageInput.bgra8888(
        bytes: Uint8List.fromList(const [0, 0, 0, 255]),
        width: 1,
        height: 1,
      ),
      isCancelled: () => false,
    );

    expect(receivedCall?.arguments, {
      'bytes': Uint8List.fromList(const [0, 0, 0, 255]),
      'format': 'bgra8888',
      'width': 1,
      'height': 1,
    });
  });

  test('maps native failures without leaking their details', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(
            code: 'decode_failed',
            message: 'PRIVATE VISION DETAIL',
          ),
        );

    await expectLater(
      AppleVisionOcr().recognize(
        image: OcrImageInput.encoded(Uint8List.fromList(const [1])),
        isCancelled: () => false,
      ),
      throwsA(
        isA<OcrException>()
            .having((error) => error.code, 'code', OcrFailureCode.decodeFailed)
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('PRIVATE')),
            ),
      ),
    );
  });

  test('honors cancellation before invoking Vision', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          invoked = true;
          return <String, Object>{'text': 'unused', 'confidence': 1};
        });

    await expectLater(
      AppleVisionOcr().recognize(
        image: OcrImageInput.encoded(Uint8List.fromList(const [1])),
        isCancelled: () => true,
      ),
      throwsA(
        isA<OcrException>().having(
          (error) => error.code,
          'code',
          OcrFailureCode.cancelled,
        ),
      ),
    );
    expect(invoked, isFalse);
  });
}
