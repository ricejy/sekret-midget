import 'package:flutter/services.dart';

import 'ocr_engine.dart';

final class AppleVisionOcr implements OcrEngine {
  AppleVisionOcr({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.ricejy.sekret_midget/vision_ocr';

  final MethodChannel _channel;

  @override
  Future<OcrRecognition> recognize({
    required OcrImageInput image,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) {
      throw const OcrException(OcrFailureCode.cancelled, 'OCR was cancelled.');
    }
    if (image.bytes.isEmpty) {
      throw const OcrException(
        OcrFailureCode.invalidInput,
        'The selected image is empty.',
      );
    }
    try {
      final payload = await _channel
          .invokeMapMethod<Object?, Object?>('recognize', {
            'bytes': image.bytes,
            'format': image.format.name,
            'width': ?image.width,
            'height': ?image.height,
          });
      if (isCancelled()) {
        throw const OcrException(
          OcrFailureCode.cancelled,
          'OCR was cancelled.',
        );
      }
      final text = payload?['text'];
      final confidence = payload?['confidence'];
      if (text is! String || confidence is! num) {
        throw const OcrException(
          OcrFailureCode.recognitionFailed,
          'The Vision bridge returned an invalid result.',
        );
      }
      return OcrRecognition(
        text: text.trim(),
        confidence: confidence.toDouble().clamp(0, 1),
      );
    } on MissingPluginException {
      throw const OcrException(
        OcrFailureCode.unavailable,
        'The Apple Vision OCR bridge is unavailable.',
      );
    } on PlatformException catch (error) {
      throw OcrException(_failureCode(error.code), _safeMessage(error.code));
    }
  }

  OcrFailureCode _failureCode(String code) => switch (code) {
    'vision_unavailable' => OcrFailureCode.unavailable,
    'invalid_input' => OcrFailureCode.invalidInput,
    'decode_failed' => OcrFailureCode.decodeFailed,
    'cancelled' => OcrFailureCode.cancelled,
    _ => OcrFailureCode.recognitionFailed,
  };

  String _safeMessage(String code) => switch (code) {
    'vision_unavailable' => 'Apple Vision text recognition is unavailable.',
    'invalid_input' => 'The image supplied to OCR was invalid.',
    'decode_failed' => 'The selected image could not be decoded.',
    'cancelled' => 'OCR was cancelled.',
    _ => 'Apple Vision could not recognize this document.',
  };
}
