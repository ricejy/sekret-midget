import 'dart:io';
import 'package:flutter/services.dart';
import 'document_image_picker.dart';
import 'file_selector_document_image_picker.dart';

/// The iPhone action opens Photos, not Files. Only the chosen image is shared
/// with Sekret; no full-library permission or temporary file is needed.
final class PhotosDocumentImagePicker implements DocumentImagePicker {
  const PhotosDocumentImagePicker();
  static const _channel = MethodChannel('com.ricejy.sekret_midget/photos');

  @override
  Future<SelectedDocumentImage?> pickImage() async {
    if (!Platform.isIOS) {
      return const FileSelectorDocumentImagePicker().pickImage();
    }
    final result = await _channel.invokeMapMethod<String, Object?>('pickImage');
    if (result == null) return null;
    final name = result['name'];
    final bytes = result['bytes'];
    if (name is! String || bytes is! Uint8List || bytes.isEmpty) {
      throw const FormatException('The selected photograph could not be read.');
    }
    return SelectedDocumentImage(name: name, bytes: bytes);
  }
}
