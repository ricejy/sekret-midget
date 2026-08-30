import 'dart:typed_data';

import 'ocr_engine.dart';

final class RasterizedPdfPage {
  const RasterizedPdfPage({required this.pageNumber, required this.image});

  final int pageNumber;
  final OcrImageInput image;
}

enum PdfRasterFailureCode {
  malformed,
  passwordProtected,
  unsupported,
  cancelled,
  renderingFailed,
}

final class PdfRasterException implements Exception {
  const PdfRasterException(this.code, this.message);

  final PdfRasterFailureCode code;
  final String message;

  @override
  String toString() => 'PdfRasterException(${code.name}): $message';
}

abstract interface class PdfPageRasterizer {
  Future<List<RasterizedPdfPage>> rasterize({
    required Uint8List bytes,
    required String sourceName,
    required List<int> pageNumbers,
    required bool Function() isCancelled,
  });
}

final class UnavailablePdfPageRasterizer implements PdfPageRasterizer {
  const UnavailablePdfPageRasterizer();

  @override
  Future<List<RasterizedPdfPage>> rasterize({
    required Uint8List bytes,
    required String sourceName,
    required List<int> pageNumbers,
    required bool Function() isCancelled,
  }) {
    throw const PdfRasterException(
      PdfRasterFailureCode.unsupported,
      'Scanned PDF rendering is unavailable on this platform.',
    );
  }
}

abstract interface class PdfRasterDocument {
  int get pageCount;

  Future<OcrImageInput> rasterizePage(int pageNumber);

  Future<void> dispose();
}

abstract interface class PdfRasterDocumentLoader {
  Future<PdfRasterDocument> open({
    required Uint8List bytes,
    required String sourceName,
  });
}
