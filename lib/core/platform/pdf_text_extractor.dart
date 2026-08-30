import 'dart:typed_data';

final class ExtractedPdfPage {
  const ExtractedPdfPage({required this.pageNumber, required this.text});

  final int pageNumber;
  final String text;
}

final class ExtractedPdf {
  const ExtractedPdf({required this.pages});

  final List<ExtractedPdfPage> pages;
}

enum PdfExtractionFailureCode {
  malformed,
  passwordProtected,
  unsupported,
  cancelled,
  extractionFailed,
}

final class PdfExtractionException implements Exception {
  const PdfExtractionException(this.code, this.message);

  final PdfExtractionFailureCode code;
  final String message;

  @override
  String toString() => 'PdfExtractionException(${code.name}): $message';
}

abstract interface class PdfTextExtractor {
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  });
}

abstract interface class PdfTextDocument {
  int get pageCount;

  Future<String> loadPageText(int pageNumber);

  Future<void> dispose();
}

abstract interface class PdfTextDocumentLoader {
  Future<PdfTextDocument> open({
    required Uint8List bytes,
    required String sourceName,
  });
}

final class UnavailablePdfTextExtractor implements PdfTextExtractor {
  const UnavailablePdfTextExtractor();

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) {
    throw const PdfExtractionException(
      PdfExtractionFailureCode.unsupported,
      'PDF text extraction is unavailable on this platform.',
    );
  }
}
