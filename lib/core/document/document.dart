final class Document {
  const Document({required this.title, required this.chunks});

  final String title;
  final List<DocumentChunk> chunks;
}

final class DocumentChunk {
  const DocumentChunk({
    required this.text,
    required this.page,
    required this.heading,
  });

  final String text;
  final int page;
  final String heading;
}
