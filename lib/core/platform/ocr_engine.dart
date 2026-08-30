import 'dart:typed_data';

enum OcrImageFormat { encoded, bgra8888 }

final class OcrImageInput {
  const OcrImageInput.encoded(this.bytes)
    : format = OcrImageFormat.encoded,
      width = null,
      height = null;

  const OcrImageInput.bgra8888({
    required this.bytes,
    required this.width,
    required this.height,
  }) : format = OcrImageFormat.bgra8888;

  final Uint8List bytes;
  final OcrImageFormat format;
  final int? width;
  final int? height;
}

final class OcrRecognition {
  const OcrRecognition({required this.text, required this.confidence});

  final String text;
  final double confidence;
}

enum OcrFailureCode {
  unavailable,
  invalidInput,
  decodeFailed,
  recognitionFailed,
  cancelled,
}

final class OcrException implements Exception {
  const OcrException(this.code, this.message);

  final OcrFailureCode code;
  final String message;

  @override
  String toString() => 'OcrException(${code.name}): $message';
}

abstract interface class OcrEngine {
  Future<OcrRecognition> recognize({
    required OcrImageInput image,
    required bool Function() isCancelled,
  });
}

final class UnavailableOcrEngine implements OcrEngine {
  const UnavailableOcrEngine();

  @override
  Future<OcrRecognition> recognize({
    required OcrImageInput image,
    required bool Function() isCancelled,
  }) {
    throw const OcrException(
      OcrFailureCode.unavailable,
      'On-device OCR is unavailable on this platform.',
    );
  }
}
