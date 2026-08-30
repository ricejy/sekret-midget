import 'package:file_selector/file_selector.dart';

import 'document_image_picker.dart';

final class FileSelectorDocumentImagePicker implements DocumentImagePicker {
  const FileSelectorDocumentImagePicker();

  @override
  Future<SelectedDocumentImage?> pickImage() async {
    const imageType = XTypeGroup(
      label: 'Document photos',
      extensions: ['jpg', 'jpeg', 'png', 'heic', 'heif', 'tif', 'tiff'],
      uniformTypeIdentifiers: ['public.image'],
      mimeTypes: ['image/*'],
    );
    final file = await openFile(
      acceptedTypeGroups: const [imageType],
      confirmButtonText: 'Import Photo',
    );
    if (file == null) {
      return null;
    }
    return SelectedDocumentImage(
      name: file.name,
      bytes: await file.readAsBytes(),
    );
  }
}
