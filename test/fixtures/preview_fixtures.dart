import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Small, self-contained originals for the same Mac/Windows/iPhone scenarios.
/// Generated only by tests; no fixture assets ship in the production app.
Future<({Uint8List photo, Uint8List scan, Uint8List pdf})>
previewFixtures() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final paragraph =
      (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 24))
            ..pushStyle(ui.TextStyle(color: const ui.Color(0xff182436)))
            ..addText(
              'FICTIONAL EQUIPMENT POLICY\n\nReturn equipment within seven days.\n\nKeep equipment dry.',
            ))
          .build()
        ..layout(const ui.ParagraphConstraints(width: 420));
  canvas.drawParagraph(paragraph, const ui.Offset(24, 48));
  final picture = recorder.endRecording();
  final image = await picture.toImage(480, 640);
  final photo = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  final rgba = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  final rgb = <int>[];
  for (var i = 0; i < rgba.length; i += 4) {
    rgb.addAll(rgba.sublist(i, i + 3));
  }
  image.dispose();
  picture.dispose();
  paragraph.dispose();
  final compressed = ZLibEncoder().convert(rgb);
  return (
    photo: photo,
    scan: _pdf([
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 480 640] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>',
      _stream('q 480 0 0 640 0 0 cm /Im0 Do Q'),
      '<< /Type /XObject /Subtype /Image /Width 480 /Height 640 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ${compressed.length} >>\nstream\n${latin1.decode(compressed)}\nendstream',
    ]),
    pdf: _pdf([
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 480 640] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 480 640] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
      _stream(
        'BT /F1 18 Tf 30 590 Td (Fictional return policy) Tj 0 -40 Td (Return equipment within seven days.) Tj ET',
      ),
      _stream(
        'BT /F1 18 Tf 30 590 Td (Storage instructions) Tj 0 -40 Td (Keep equipment dry.) Tj ET',
      ),
    ]),
  );
}

String _stream(String data) =>
    '<< /Length ${latin1.encode(data).length} >>\nstream\n$data\nendstream';

Uint8List _pdf(List<String> objects) {
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF',
  );
  return Uint8List.fromList(latin1.encode(output.toString()));
}
