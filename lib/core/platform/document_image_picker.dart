import 'dart:typed_data';

final class SelectedDocumentImage {
  const SelectedDocumentImage({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

abstract interface class DocumentImagePicker {
  Future<SelectedDocumentImage?> pickImage();
}
