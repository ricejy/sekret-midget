import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/platform/ocr_engine.dart';
import 'package:sekret_midget/core/platform/pdf_page_rasterizer.dart';
import 'package:sekret_midget/core/platform/pdfrx_pdf_page_rasterizer.dart';

void main() {
  test(
    'rasterizes only requested PDF pages and disposes the document',
    () async {
      final document = _FakeRasterDocument(pageCount: 3);
      final rasterized =
          await PdfrxPdfPageRasterizer(
            loader: _FakeRasterLoader(document),
          ).rasterize(
            bytes: Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
            sourceName: 'fictional-scan.pdf',
            pageNumbers: const [1, 3],
            isCancelled: () => false,
          );

      expect(rasterized.map((page) => page.pageNumber), [1, 3]);
      expect(document.requestedPages, [1, 3]);
      expect(rasterized, hasLength(2));
      expect(rasterized.first.image.format, OcrImageFormat.bgra8888);
      expect(document.disposed, isTrue);
    },
  );

  test('rejects an invalid page without returning partial images', () async {
    final document = _FakeRasterDocument(pageCount: 2);

    await expectLater(
      PdfrxPdfPageRasterizer(loader: _FakeRasterLoader(document)).rasterize(
        bytes: Uint8List.fromList(const [1]),
        sourceName: 'fictional-scan.pdf',
        pageNumbers: const [3],
        isCancelled: () => false,
      ),
      throwsA(
        isA<PdfRasterException>().having(
          (error) => error.code,
          'code',
          PdfRasterFailureCode.renderingFailed,
        ),
      ),
    );
    expect(document.disposed, isTrue);
  });

  test('honors cancellation before opening PDF bytes', () async {
    final loader = _FakeRasterLoader(_FakeRasterDocument(pageCount: 1));

    await expectLater(
      PdfrxPdfPageRasterizer(loader: loader).rasterize(
        bytes: Uint8List.fromList(const [1]),
        sourceName: 'fictional-scan.pdf',
        pageNumbers: const [1],
        isCancelled: () => true,
      ),
      throwsA(
        isA<PdfRasterException>().having(
          (error) => error.code,
          'code',
          PdfRasterFailureCode.cancelled,
        ),
      ),
    );
    expect(loader.wasOpened, isFalse);
  });
}

final class _FakeRasterLoader implements PdfRasterDocumentLoader {
  _FakeRasterLoader(this.document);

  final _FakeRasterDocument document;
  bool wasOpened = false;

  @override
  Future<PdfRasterDocument> open({
    required Uint8List bytes,
    required String sourceName,
  }) async {
    wasOpened = true;
    return document;
  }
}

final class _FakeRasterDocument implements PdfRasterDocument {
  _FakeRasterDocument({required this.pageCount});

  @override
  final int pageCount;
  final requestedPages = <int>[];
  bool disposed = false;

  @override
  Future<OcrImageInput> rasterizePage(int pageNumber) async {
    requestedPages.add(pageNumber);
    return OcrImageInput.bgra8888(
      bytes: Uint8List.fromList(const [0, 0, 0, 255]),
      width: 1,
      height: 1,
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
