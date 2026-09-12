import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/chat/chat_workspace.dart';
import '../../core/knowledge/knowledge_base.dart';
import '../../core/storage/local_data_vault.dart';
import '../accessible_controls.dart';

String processingLabel(KnowledgeProcessingState state) => switch (state) {
  KnowledgeProcessingState.processing => 'Processing',
  KnowledgeProcessingState.paused => 'Paused',
  KnowledgeProcessingState.indexed => 'Indexed',
  KnowledgeProcessingState.failed => 'Failed',
  KnowledgeProcessingState.needsReindexing => 'Needs re-indexing',
};

class ChatHistory extends StatefulWidget {
  const ChatHistory({super.key, required this.workspace, required this.isBusy});
  final ChatWorkspace workspace;
  final bool Function() isBusy;
  @override
  State<ChatHistory> createState() => _ChatHistoryState();
}

class _ChatHistoryState extends State<ChatHistory> {
  final _search = TextEditingController();
  List<ChatRecord> _chats = [];
  StreamSubscription<void>? _changes;
  String? _undoId;
  String? _error;
  Timer? _undoTimer;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    _changes = widget.workspace.changes.listen((_) => _load());
    _load();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      final chats = await widget.workspace.history(query: _search.text);
      if (mounted && revision == _revision) {
        setState(() => _chats = List.of(chats));
      }
    } on Object {
      if (mounted) setState(() => _error = 'Could not load chats.');
    }
  }

  Future<void> _delete(ChatRecord chat) async {
    if (widget.isBusy()) return;
    try {
      await widget.workspace.deleteChat(chat.id);
      if (!mounted) return;
      setState(() => _undoId = chat.id);
      _undoTimer?.cancel();
      _undoTimer = Timer(widget.workspace.undoWindow, () {
        if (mounted) setState(() => _undoId = null);
      });
    } on Object {
      if (mounted) setState(() => _error = 'Could not delete this chat.');
    }
  }

  Future<void> _rename(ChatRecord chat) async {
    final input = TextEditingController(text: chat.title);
    final title = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Rename chat'),
        content: CupertinoTextField(
          controller: input,
          autofocus: true,
          placeholder: 'Chat title',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // The dialog's exit animation can still reference its editing controller.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    input.dispose();
    if (title != null) {
      try {
        await widget.workspace.rename(chat.id, title);
      } on Object {
        if (mounted) setState(() => _error = 'Could not rename this chat.');
      }
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _undoTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: const Text('Chats'),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ),
    child: SafeArea(
      child: PanelAndContent(
        panel: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: CupertinoSearchTextField(
                controller: _search,
                placeholder: 'Search chats',
                onChanged: (_) => _load(),
              ),
            ),
            if (_error != null) Text(_error!),
            if (_undoId != null) _undoAction(),
          ],
        ),
        content: _chats.isEmpty
            ? const Center(child: Text('No chats found'))
            : ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  for (final chat in _chats)
                    Dismissible(
                      key: ValueKey(chat.id),
                      direction: widget.isBusy()
                          ? DismissDirection.none
                          : DismissDirection.endToStart,
                      background: Container(
                        color: CupertinoColors.systemRed,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.all(16),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: CupertinoColors.white),
                        ),
                      ),
                      onDismissed: (_) {
                        setState(
                          () => _chats.removeWhere((c) => c.id == chat.id),
                        );
                        _delete(chat);
                      },
                      child: Row(
                        children: [
                          Expanded(
                            child: WrappingListAction(
                              title: chat.title,
                              subtitle:
                                  chat.id == widget.workspace.currentChatId
                                  ? 'Current chat'
                                  : 'Saved on this device',
                              onPressed: () async {
                                await widget.workspace.openChat(chat.id);
                                if (context.mounted) Navigator.pop(context);
                              },
                            ),
                          ),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => _rename(chat),
                            child: const Icon(
                              CupertinoIcons.pencil,
                              semanticLabel: 'Rename chat',
                            ),
                          ),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: widget.isBusy()
                                ? null
                                : () => _delete(chat),
                            child: const Icon(
                              CupertinoIcons.trash,
                              semanticLabel: 'Delete chat',
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    ),
  );

  Widget _undoAction() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Semantics(liveRegion: true, child: const Text('Chat deleted')),
      CupertinoButton(
        onPressed: () async {
          final id = _undoId;
          if (id == null) return;
          final restored = await widget.workspace.undoDelete(id);
          if (mounted) {
            setState(() {
              _undoId = null;
              if (!restored) _error = 'Undo has expired.';
            });
          }
        },
        child: const Text('Undo'),
      ),
    ],
  );
}

class SourceSelection extends StatefulWidget {
  const SourceSelection({
    super.key,
    required this.knowledge,
    required this.selected,
  });
  final KnowledgeBase knowledge;
  final List<String> selected;
  @override
  State<SourceSelection> createState() => _SourceSelectionState();
}

class _SourceSelectionState extends State<SourceSelection> {
  late final Set<String> _selected = widget.selected.toSet();
  final _search = TextEditingController();
  List<CatalogueMatch> _items = [];
  StreamSubscription<void>? _changes;
  int _revision = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _changes = widget.knowledge.changes.listen((_) => _load());
    _load();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      final items = await widget.knowledge.catalogue(query: _search.text);
      if (mounted && revision == _revision) setState(() => _items = items);
    } on Object {
      if (mounted) setState(() => _error = 'Could not load sources.');
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: const Text('Select sources'),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => Navigator.pop(context, _selected.toList()),
        child: const Text('Done'),
      ),
    ),
    child: SafeArea(
      child: PanelAndContent(
        panel: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: CupertinoSearchTextField(
                controller: _search,
                placeholder: 'Search sources',
                onChanged: (_) => _load(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Changes apply to future turns only. All selected sources must be indexed before asking.',
              ),
            ),
            if (_error != null) Text(_error!),
          ],
        ),
        content: _items.isEmpty
            ? const Center(child: Text('No sources found'))
            : ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  for (final match in _items)
                    Semantics(
                      selected: _selected.contains(match.item.id),
                      child: WrappingListAction(
                        title: match.item.title,
                        subtitle: processingLabel(match.item.processingState),
                        trailing: ExcludeSemantics(
                          child: Icon(
                            _selected.contains(match.item.id)
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.circle,
                          ),
                        ),
                        onPressed: () => setState(() {
                          if (!_selected.remove(match.item.id)) {
                            _selected.add(match.item.id);
                          }
                        }),
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}
