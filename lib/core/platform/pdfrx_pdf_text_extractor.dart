import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import 'pdf_text_extractor.dart';

final class PdfrxPdfTextExtractor implements PdfTextExtractor {
  const PdfrxPdfTextExtractor({this.loader = const PdfrxDocumentLoader()});

  final PdfTextDocumentLoader loader;

  @override
  Future<ExtractedPdf> extract({
    required Uint8List bytes,
    required String sourceName,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) {
      throw const PdfExtractionException(
        PdfExtractionFailureCode.cancelled,
        'PDF import was cancelled.',
      );
    }
    final document = await loader.open(bytes: bytes, sourceName: sourceName);
    try {
      final pages = <ExtractedPdfPage>[];
      for (var pageNumber = 1; pageNumber <= document.pageCount; pageNumber++) {
        if (isCancelled()) {
          throw const PdfExtractionException(
            PdfExtractionFailureCode.cancelled,
            'PDF import was cancelled.',
          );
        }
        pages.add(
          ExtractedPdfPage(
            pageNumber: pageNumber,
            text: (await document.loadPageText(pageNumber)).trim(),
          ),
        );
      }
      return ExtractedPdf(pages: List.unmodifiable(pages));
    } on PdfExtractionException {
      rethrow;
    } on Object {
      throw const PdfExtractionException(
        PdfExtractionFailureCode.extractionFailed,
        'PDF text extraction failed.',
      );
    } finally {
      await document.dispose();
    }
  }
}

final class PdfrxDocumentLoader implements PdfTextDocumentLoader {
  const PdfrxDocumentLoader();

  static Future<void>? _initialization;

  @override
  Future<PdfTextDocument> open({
    required Uint8List bytes,
    required String sourceName,
  }) async {
    try {
      final initialization = _initialization ??= pdfrxFlutterInitialize();
      try {
        await initialization;
      } on Object {
        if (identical(_initialization, initialization)) {
          _initialization = null;
        }
        rethrow;
      }
      final document = await PdfDocument.openData(
        bytes,
        sourceName: sourceName,
      );
      return _PdfrxTextDocument(document);
    } on PdfPasswordException {
      throw const PdfExtractionException(
        PdfExtractionFailureCode.passwordProtected,
        'Password-protected PDFs are not supported yet.',
      );
    } on PdfException {
      throw const PdfExtractionException(
        PdfExtractionFailureCode.malformed,
        'The selected PDF could not be read.',
      );
    } on Object {
      throw const PdfExtractionException(
        PdfExtractionFailureCode.extractionFailed,
        'PDF text extraction failed.',
      );
    }
  }
}

final class _PdfrxTextDocument implements PdfTextDocument {
  const _PdfrxTextDocument(this._document);

  final PdfDocument _document;

  @override
  int get pageCount => _document.pages.length;

  @override
  Future<String> loadPageText(int pageNumber) async {
    final pageText = await _document.pages[pageNumber - 1].loadStructuredText();
    return pageText.fullText;
  }

  @override
  Future<void> dispose() => _document.dispose();
}
