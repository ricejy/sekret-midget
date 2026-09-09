import 'package:flutter/cupertino.dart';

class RenameKnowledge extends StatefulWidget {
  const RenameKnowledge({super.key, required this.title});
  final String title;
  @override
  State<RenameKnowledge> createState() => _RenameKnowledgeState();
}

class _RenameKnowledgeState extends State<RenameKnowledge> {
  late final _input = TextEditingController(text: widget.title);
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: const Text('Rename source'),
    content: CupertinoTextField(
      controller: _input,
      placeholder: 'Title',
      autofocus: true,
      onChanged: (_) => setState(() {}),
    ),
    actions: [
      CupertinoDialogAction(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      CupertinoDialogAction(
        onPressed: _input.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _input.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}
