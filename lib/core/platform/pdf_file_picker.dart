import 'dart:typed_data';

final class SelectedPdfFile {
  const SelectedPdfFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

abstract interface class PdfFilePicker {
  Future<SelectedPdfFile?> pickPdf();
}
