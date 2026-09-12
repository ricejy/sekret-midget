import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

/// Markdown is parsed into native widgets, never HTML/WebViews. Images (remote,
/// file, or data URLs) are text only. Links require an explicit caller action.
class AnswerContent extends StatelessWidget {
  const AnswerContent({super.key, required this.text, required this.onLink});
  final String text;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) {
    final nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parseLines(text.split('\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final node in nodes) _block(context, node)],
    );
  }

  Widget _block(BuildContext context, md.Node node) {
    if (node is! md.Element) return SelectableText(node.textContent);
    final children = node.children ?? [];
    if (node.tag == 'pre') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: node.textContent)),
                child: const Text('Copy code'),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                node.textContent,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );
    }
    if (node.tag == 'table') {
      final rows = <md.Element>[];
      void collect(md.Node n) {
        if (n is md.Element) {
          if (n.tag == 'tr') {
            rows.add(n);
          } else {
            n.children?.forEach(collect);
          }
        }
      }

      collect(node);
      final columns = rows.fold<int>(
        0,
        (n, row) => n > (row.children?.length ?? 0) ? n : row.children!.length,
      );
      if (columns == 0) return const SizedBox.shrink();
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const FixedColumnWidth(180),
          border: TableBorder.all(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
          children: [
            for (final row in rows)
              TableRow(
                children: [
                  for (var i = 0; i < columns; i++)
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: i < row.children!.length
                          ? _block(context, row.children![i])
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
          ],
        ),
      );
    }
    if (node.tag == 'ul' || node.tag == 'ol') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 6),
                  child: Text(node.tag == 'ol' ? '${i + 1}.' : '•'),
                ),
                Expanded(child: _block(context, children[i])),
              ],
            ),
        ],
      );
    }
    if (children.any(
      (n) =>
          n is md.Element &&
          {'p', 'ul', 'ol', 'pre', 'blockquote'}.contains(n.tag),
    )) {
      return Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final n in children) _block(context, n)],
        ),
      );
    }
    final heading = RegExp(r'^h[1-6]$').hasMatch(node.tag);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        header: heading || node.tag == 'th',
        child: SelectableText.rich(
          TextSpan(children: [for (final n in children) _inline(context, n)]),
          style: TextStyle(
            height: 1.45,
            fontSize: heading ? 21 : 17,
            fontWeight: heading || node.tag == 'th'
                ? FontWeight.w600
                : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  InlineSpan _inline(BuildContext context, md.Node node) {
    if (node is! md.Element) return TextSpan(text: node.textContent);
    if (node.tag == 'img') {
      return TextSpan(text: '[Image: ${node.attributes['alt'] ?? ''}]');
    }
    if (node.tag == 'br') return const TextSpan(text: '\n');
    if (node.tag == 'a') {
      final uri = Uri.tryParse(node.attributes['href'] ?? '');
      if (uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            onPressed: () => onLink(uri),
            child: Text(node.textContent),
          ),
        );
      }
      return TextSpan(text: node.textContent);
    }
    return TextSpan(
      style: TextStyle(
        fontWeight: node.tag == 'strong' ? FontWeight.w600 : null,
        fontStyle: node.tag == 'em' ? FontStyle.italic : null,
        fontFamily: node.tag == 'code' ? 'monospace' : null,
        decoration: node.tag == 'del' ? TextDecoration.lineThrough : null,
      ),
      children: [
        for (final child in node.children ?? <md.Node>[])
          _inline(context, child),
      ],
    );
  }
}
