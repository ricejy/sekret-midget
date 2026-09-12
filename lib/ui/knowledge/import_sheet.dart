import 'package:flutter/cupertino.dart';
import '../../core/knowledge/knowledge_base.dart';
import '../accessible_controls.dart';

/// Owns its text controllers through the route's exit animation.
class PasteKnowledge extends StatefulWidget {
  const PasteKnowledge({super.key, required this.knowledge});
  final KnowledgeBase knowledge;
  @override
  State<PasteKnowledge> createState() => _PasteKnowledgeState();
}

class _PasteKnowledgeState extends State<PasteKnowledge> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving || _title.text.trim().isEmpty || _text.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.knowledge.importText(
        title: _title.text,
        text: _text.text,
      );
      if (mounted) Navigator.pop(context, result);
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error =
              'Could not import this text. Return to the app and try again.';
        });
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        middle: const Text('Paste text'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed:
              _saving || _title.text.trim().isEmpty || _text.text.trim().isEmpty
              ? null
              : _save,
          child: const Text('Import'),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: PanelAndContent(
            panel: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CupertinoTextField(
                  controller: _title,
                  placeholder: 'Title',
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!),
                  ),
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Saved and indexed on this device.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            content: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CupertinoTextField(
                controller: _text,
                placeholder: 'Paste your text',
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
