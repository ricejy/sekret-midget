import 'package:file_selector/file_selector.dart';

import 'pdf_file_picker.dart';

final class FileSelectorPdfPicker implements PdfFilePicker {
  const FileSelectorPdfPicker();

  @override
  Future<SelectedPdfFile?> pickPdf() async {
    const pdfType = XTypeGroup(
      label: 'PDF documents',
      extensions: ['pdf'],
      uniformTypeIdentifiers: ['com.adobe.pdf'],
      mimeTypes: ['application/pdf'],
    );
    final file = await openFile(
      acceptedTypeGroups: const [pdfType],
      confirmButtonText: 'Import PDF',
    );
    if (file == null) {
      return null;
    }
    return SelectedPdfFile(name: file.name, bytes: await file.readAsBytes());
  }
}
