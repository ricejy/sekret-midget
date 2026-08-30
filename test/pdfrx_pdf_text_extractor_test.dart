import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/platform/pdf_text_extractor.dart';
import 'package:sekret_midget/core/platform/pdfrx_pdf_text_extractor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extracts a text-layer PDF page by page', () async {
    final bytes = await File(
      'test/fixtures/fictional_text_contract.pdf',
    ).readAsBytes();
    final loader = _RecordingDocumentLoader(
      document: _FakeTextDocument(const [
        'FICTIONAL MERIDIAN EMPLOYMENT AGREEMENT',
        'NOTICE PERIOD\nEither fictional party must provide forty-five calendar days.',
        'COMPENSATION DATE\nCompensation is paid on the final business day.',
      ]),
    );

    final extracted = await PdfrxPdfTextExtractor(loader: loader).extract(
      bytes: bytes,
      sourceName: 'fictional_text_contract.pdf',
      isCancelled: () => false,
    );

    expect(loader.openedBytes!.sublist(0, 4), <int>[0x25, 0x50, 0x44, 0x46]);
    expect(loader.sourceName, 'fictional_text_contract.pdf');
    expect(loader.document.disposed, isTrue);
    expect(extracted.pages, hasLength(3));
    expect(extracted.pages[0].pageNumber, 1);
    expect(
      extracted.pages[0].text,
      contains('FICTIONAL MERIDIAN EMPLOYMENT AGREEMENT'),
    );
    expect(extracted.pages[1].pageNumber, 2);
    expect(extracted.pages[1].text, contains('NOTICE PERIOD'));
    expect(extracted.pages[1].text, contains('forty-five calendar days'));
    expect(extracted.pages[2].pageNumber, 3);
    expect(extracted.pages[2].text, contains('COMPENSATION DATE'));
  });

  test('maps malformed bytes to a sanitized extraction failure', () async {
    final loader = _ThrowingDocumentLoader(
      const PdfExtractionException(
        PdfExtractionFailureCode.malformed,
        'The selected PDF could not be read.',
      ),
    );
    await expectLater(
      PdfrxPdfTextExtractor(loader: loader).extract(
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        sourceName: 'malformed.pdf',
        isCancelled: () => false,
      ),
      throwsA(
        isA<PdfExtractionException>()
            .having(
              (error) => error.code,
              'code',
              PdfExtractionFailureCode.malformed,
            )
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('malformed.pdf')),
            ),
      ),
    );
  });

  test('honors cancellation before opening document bytes', () async {
    final loader = _RecordingDocumentLoader(
      document: _FakeTextDocument(const ['unused']),
    );
    await expectLater(
      PdfrxPdfTextExtractor(loader: loader).extract(
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        sourceName: 'cancelled.pdf',
        isCancelled: () => true,
      ),
      throwsA(
        isA<PdfExtractionException>().having(
          (error) => error.code,
          'code',
          PdfExtractionFailureCode.cancelled,
        ),
      ),
    );
    expect(loader.wasOpened, isFalse);
  });

  test('disposes the document after a page extraction failure', () async {
    final document = _FakeTextDocument(const [
      'first page',
    ], failure: StateError('native detail that must not escape'));

    await expectLater(
      PdfrxPdfTextExtractor(
        loader: _RecordingDocumentLoader(document: document),
      ).extract(
        bytes: Uint8List.fromList(const [1]),
        sourceName: 'fixture.pdf',
        isCancelled: () => false,
      ),
      throwsA(
        isA<PdfExtractionException>()
            .having(
              (error) => error.code,
              'code',
              PdfExtractionFailureCode.extractionFailed,
            )
            .having(
              (error) => error.message,
              'sanitized message',
              isNot(contains('native detail')),
            ),
      ),
    );
    expect(document.disposed, isTrue);
  });
}

final class _RecordingDocumentLoader implements PdfTextDocumentLoader {
  _RecordingDocumentLoader({required this.document});

  final _FakeTextDocument document;
  Uint8List? openedBytes;
  String? sourceName;

  bool get wasOpened => openedBytes != null;

  @override
  Future<PdfTextDocument> open({
    required Uint8List bytes,
    required String sourceName,
  }) async {
    openedBytes = bytes;
    this.sourceName = sourceName;
    return document;
  }
}

final class _ThrowingDocumentLoader implements PdfTextDocumentLoader {
  const _ThrowingDocumentLoader(this.error);

  final Object error;

  @override
  Future<PdfTextDocument> open({
    required Uint8List bytes,
    required String sourceName,
  }) async {
    throw error;
  }
}

final class _FakeTextDocument implements PdfTextDocument {
  _FakeTextDocument(this.pages, {this.failure});

  final List<String> pages;
  final Object? failure;
  bool disposed = false;

  @override
  int get pageCount => pages.length;

  @override
  Future<String> loadPageText(int pageNumber) async {
    if (failure case final failure?) {
      throw failure;
    }
    return pages[pageNumber - 1];
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
