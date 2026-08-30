import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import 'ocr_engine.dart';
import 'pdf_page_rasterizer.dart';

final class PdfrxPdfPageRasterizer implements PdfPageRasterizer {
  const PdfrxPdfPageRasterizer({
    this.loader = const PdfrxRasterDocumentLoader(),
  });

  final PdfRasterDocumentLoader loader;

  @override
  Future<List<RasterizedPdfPage>> rasterize({
    required Uint8List bytes,
    required String sourceName,
    required List<int> pageNumbers,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) {
      throw const PdfRasterException(
        PdfRasterFailureCode.cancelled,
        'Scanned PDF rendering was cancelled.',
      );
    }
    final document = await loader.open(bytes: bytes, sourceName: sourceName);
    try {
      final rendered = <RasterizedPdfPage>[];
      for (final pageNumber in pageNumbers) {
        if (isCancelled()) {
          throw const PdfRasterException(
            PdfRasterFailureCode.cancelled,
            'Scanned PDF rendering was cancelled.',
          );
        }
        if (pageNumber < 1 || pageNumber > document.pageCount) {
          throw const PdfRasterException(
            PdfRasterFailureCode.renderingFailed,
            'A scanned PDF page could not be rendered.',
          );
        }
        rendered.add(
          RasterizedPdfPage(
            pageNumber: pageNumber,
            image: await document.rasterizePage(pageNumber),
          ),
        );
      }
      return List.unmodifiable(rendered);
    } on PdfRasterException {
      rethrow;
    } on Object {
      throw const PdfRasterException(
        PdfRasterFailureCode.renderingFailed,
        'A scanned PDF page could not be rendered.',
      );
    } finally {
      await document.dispose();
    }
  }
}

final class PdfrxRasterDocumentLoader implements PdfRasterDocumentLoader {
  const PdfrxRasterDocumentLoader();

  static Future<void>? _initialization;

  @override
  Future<PdfRasterDocument> open({
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
      return _PdfrxRasterDocument(
        await PdfDocument.openData(bytes, sourceName: sourceName),
      );
    } on PdfPasswordException {
      throw const PdfRasterException(
        PdfRasterFailureCode.passwordProtected,
        'Password-protected PDFs are not supported yet.',
      );
    } on PdfException {
      throw const PdfRasterException(
        PdfRasterFailureCode.malformed,
        'The selected PDF could not be rendered.',
      );
    } on Object {
      throw const PdfRasterException(
        PdfRasterFailureCode.renderingFailed,
        'The scanned PDF could not be rendered.',
      );
    }
  }
}

final class _PdfrxRasterDocument implements PdfRasterDocument {
  const _PdfrxRasterDocument(this._document);

  static const _targetDpi = 200.0;
  static const _maximumLongEdge = 2400.0;

  final PdfDocument _document;

  @override
  int get pageCount => _document.pages.length;

  @override
  Future<OcrImageInput> rasterizePage(int pageNumber) async {
    final page = _document.pages[pageNumber - 1];
    final scale = math.min(
      _targetDpi / 72,
      _maximumLongEdge / math.max(page.width, page.height),
    );
    final image = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xffffffff,
    );
    if (image == null) {
      throw const PdfRasterException(
        PdfRasterFailureCode.renderingFailed,
        'A scanned PDF page could not be rendered.',
      );
    }
    try {
      return OcrImageInput.bgra8888(
        bytes: Uint8List.fromList(image.pixels),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }

  @override
  Future<void> dispose() => _document.dispose();
}
