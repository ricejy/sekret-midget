import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:pdfrx/pdfrx.dart';
import '../../core/knowledge/knowledge_base.dart';
import '../../core/storage/local_data_vault.dart';

/// Citation destination. #26 expands catalogue preview navigation/search.
class SourcePreview extends StatelessWidget {
  const SourcePreview({super.key, required this.preview});
  final KnowledgePreview preview;
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(preview.item.title)),
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preview.location.page != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Page ${preview.location.page}'),
            ),
          if (preview.location.text?.isNotEmpty ?? false)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Captured passage',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SelectableText(preview.location.text!),
                  ],
                ),
              ),
            ),
          Expanded(
            child: switch (preview.item.sourceType) {
              KnowledgeSourceType.pastedText => SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: SelectableText(utf8.decode(preview.source.bytes)),
              ),
              KnowledgeSourceType.pdf => PdfViewer.data(
                preview.source.bytes,
                sourceName: preview.item.title,
                initialPageNumber: preview.location.page ?? 1,
              ),
              KnowledgeSourceType.photo => InteractiveViewer(
                minScale: .5,
                maxScale: 5,
                child: Center(
                  child: Image.memory(
                    preview.source.bytes,
                    errorBuilder: (_, _, _) =>
                        const Text('Image preview unavailable.'),
                  ),
                ),
              ),
            },
          ),
        ],
      ),
    ),
  );
}
