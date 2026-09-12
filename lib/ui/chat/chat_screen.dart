import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import '../../core/chat/chat_engine.dart';
import '../../core/chat/chat_workspace.dart';
import '../../core/knowledge/knowledge_base.dart';
import '../../core/platform/llm_backend.dart';
import '../../core/storage/local_data_vault.dart';
import 'answer_content.dart';
import 'chat_sheets.dart';
import '../accessible_controls.dart';

/// UI only: the app owns the workspace, knowledge module, engine and lifecycle.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.workspace,
    required this.engine,
    required this.knowledge,
    required this.onKnowledgeBase,
    required this.onPreview,
    required this.onLink,
    this.onSettings,
  });
  final ChatWorkspace workspace;
  final ChatEngine engine;
  final KnowledgeBase knowledge;
  final VoidCallback onKnowledgeBase;
  final Future<void> Function(KnowledgePreview) onPreview;
  final Future<void> Function(Uri) onLink;
  final Future<void> Function()? onSettings;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _messageFocus = FocusNode();
  final _scroll = ScrollController();
  final _drafts = <String, String>{};
  final _expandedSources = <String>{};
  final _subscriptions = <StreamSubscription<void>>[];
  ChatRecord? _chat;
  List<TurnRecord> _turns = [];
  List<KnowledgeItemRecord> _items = [];
  LlmAvailability? _availability;
  String? _error;
  bool _summary = false;
  bool _submitting = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.add(widget.workspace.changes.listen((_) => _load()));
    _subscriptions.add(widget.knowledge.changes.listen((_) => _load()));
    _initialize();
  }

  @override
  void didChangeMetrics() {
    if (!_scroll.hasClients || _scroll.position.extentAfter < 100) _toBottom();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAvailability();
  }

  Future<void> _initialize() async {
    try {
      if (widget.workspace.currentChatId == null) {
        await widget.workspace.newChat();
      }
      await _load();
      await _checkAvailability();
    } on Object {
      _report('Could not open this chat. Try again.');
    }
  }

  Future<void> _checkAvailability() async {
    try {
      final value = await widget.engine.availability();
      if (mounted) setState(() => _availability = value);
    } on Object {
      _report('Could not check the on-device model. Try again.');
    }
  }

  void _report(String message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      final chats = await widget.workspace.history();
      final id = widget.workspace.currentChatId;
      final chat = chats.where((c) => c.id == id).firstOrNull;
      final turns = chat == null
          ? <TurnRecord>[]
          : await widget.workspace.transcript(chat.id);
      final items = await widget.knowledge.catalogue();
      final summary =
          chat != null && await widget.workspace.hasContextSummary(chat.id);
      if (!mounted || revision != _revision) return;
      final switched = _chat?.id != chat?.id;
      final nearBottom =
          !_scroll.hasClients || _scroll.position.extentAfter < 100;
      setState(() {
        if (switched) {
          if (_chat != null) _drafts[_chat!.id] = _input.text;
          _input.text = _drafts[chat?.id] ?? '';
        }
        _chat = chat;
        _turns = turns;
        _items = items.map((i) => i.item).toList();
        _summary = summary;
      });
      if (switched || nearBottom) _toBottom();
    } on Object {
      if (revision == _revision) _report('Could not refresh this chat.');
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  bool get _busy => _submitting || widget.engine.isGenerating;
  bool get _sourcesReady =>
      _chat?.mode != ChatMode.knowledgeBase ||
      (_chat!.selectedSourceIds.isNotEmpty &&
          _chat!.selectedSourceIds.every(
            (id) => _items.any(
              (item) =>
                  item.id == id &&
                  item.processingState == KnowledgeProcessingState.indexed,
            ),
          ));

  Future<void> _send({TurnRecord? regenerate}) async {
    final chat = _chat;
    if (chat == null || _busy) return;
    final text = _input.text.trim();
    if (regenerate == null &&
        (text.isEmpty || !_sourcesReady || _availability is! Available)) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    if (regenerate == null) {
      _input.clear();
      _drafts.remove(chat.id);
    }
    _toBottom();
    try {
      if (regenerate == null) {
        await widget.engine.send(chatId: chat.id, text: text);
      } else {
        await widget.engine.regenerate(chatId: chat.id, turnId: regenerate.id);
      }
    } on Object {
      if (regenerate == null) {
        _drafts[chat.id] = text;
        if (mounted && _chat?.id == chat.id && _input.text.isEmpty) {
          _input.text = text;
        }
      }
      _report(
        'Could not start this turn. Check the original sources and model, then retry.',
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
        await _load();
      }
    }
  }

  Future<void> _newChat() async {
    try {
      await widget.workspace.newChat();
      await _load();
    } on Object {
      _report('Could not start a new chat.');
    }
  }

  Future<void> _scope(ChatMode mode, List<String> ids) async {
    final chat = _chat;
    if (chat == null) return;
    try {
      await widget.workspace.changeScope(chat.id, mode, ids);
    } on Object {
      _report('Could not change selected sources.');
    }
  }

  Future<void> _chooseSources() async {
    final chat = _chat;
    if (chat == null) return;
    final selected = await Navigator.of(context).push<List<String>>(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (_) => SourceSelection(
          knowledge: widget.knowledge,
          selected: chat.selectedSourceIds,
        ),
      ),
    );
    if (selected != null && mounted && _chat?.id == chat.id) {
      await _scope(ChatMode.knowledgeBase, selected);
    }
  }

  Future<void> _openSource(TurnEvidenceSnapshot source) async {
    try {
      final preview = await widget.knowledge.resolveCitation(source);
      if (preview == null) {
        _report(
          'Source deleted. The captured passage is still available here.',
        );
        await _load();
      } else if (mounted) {
        await widget.onPreview(preview);
      }
    } on Object {
      _report('Could not open this source.');
    }
  }

  Future<void> _openLink(Uri uri) async {
    final open = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Open external link?'),
        content: Text('This leaves Sekret and may use the network.\n\n$uri'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open link'),
          ),
        ],
      ),
    );
    if (open == true) {
      try {
        await widget.onLink(uri);
      } on Object {
        _report('Could not open this link.');
      }
    }
  }

  Future<void> _actions(TurnRecord turn) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Turn actions'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'copy'),
            child: const Text('Copy answer'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'select'),
            child: const Text('Select text'),
          ),
          if (!_busy)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'regenerate'),
              child: const Text('Regenerate'),
            ),
          if (!_busy)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, 'delete'),
              child: const Text('Delete from here'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: turn.assistantText));
      return;
    }
    if (action == 'select') {
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => CupertinoPageScaffold(
            navigationBar: const CupertinoNavigationBar(
              middle: Text('Select text'),
            ),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: SelectableText(
                  '${turn.userText}\n\n${turn.assistantText}',
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (!mounted) return;
    if (action == 'regenerate' && !_busy) {
      await _send(regenerate: turn);
      return;
    }
    if (action == 'delete' && !_busy) {
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Delete from here?'),
          content: const Text(
            'This turn and every later turn in this chat will be permanently deleted.',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true && !_busy) {
        try {
          await widget.workspace.deleteFromTurn(turn.chatId, turn.id);
        } on Object {
          _report('Could not delete these turns.');
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _input.dispose();
    _messageFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      leading: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () async {
          await Navigator.of(context).push(
            CupertinoPageRoute<void>(
              builder: (_) =>
                  ChatHistory(workspace: widget.workspace, isBusy: () => _busy),
            ),
          );
          if (mounted) {
            if (widget.workspace.currentChatId == null) {
              await _newChat();
            } else {
              await _load();
            }
          }
        },
        child: const Icon(CupertinoIcons.clock, semanticLabel: 'Chat history'),
      ),
      middle: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Sekret'),
          Text(
            'On device',
            style: TextStyle(
              fontSize: 11,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _newChat,
        child: const Icon(
          CupertinoIcons.square_pencil,
          semanticLabel: 'New Chat',
        ),
      ),
    ),
    child: SafeArea(
      child: PanelAndContent(
        panelAtBottom: true,
        content: _chat == null
            ? Center(
                child: CupertinoButton(
                  onPressed: _initialize,
                  child: const Text('Open Chat'),
                ),
              )
            : ListView(
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                children: [
                  if (_turns.isEmpty) _empty(),
                  for (final turn in _turns) _turn(turn),
                  if (_summary)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Earlier conversation summarized',
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
        panel: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            _composer(),
          ],
        ),
      ),
    ),
  );

  Widget _empty() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 48),
      const Text(
        'A little space to think.',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      const Text(
        'Ask a question, work through an idea, or choose sources from your Knowledge Base.',
      ),
      const SizedBox(height: 20),
      CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: widget.onKnowledgeBase,
        child: const Text('Add to Knowledge Base'),
      ),
      for (final prompt in [
        'Help me organize an idea',
        'Explain something simply',
      ])
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: () => setState(() => _input.text = prompt),
          child: Text(prompt),
        ),
    ],
  );

  Widget _turn(TurnRecord turn) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: .86,
            alignment: Alignment.centerRight,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: CupertinoColors.tertiarySystemFill.resolveFrom(
                    context,
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SelectableText(turn.userText),
              ),
            ),
          ),
        ),
        Text(
          turn.answerLabel,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        if (turn.assistantText.isNotEmpty)
          AnswerContent(text: turn.assistantText, onLink: _openLink),
        if (turn.outcome != TurnOutcome.completed &&
            turn.outcome != TurnOutcome.insufficientEvidence)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Semantics(liveRegion: true, child: Text(_status(turn))),
          ),
        if (turn.provenance.evidence.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => setState(() {
                if (!_expandedSources.remove(turn.id)) {
                  _expandedSources.add(turn.id);
                }
              }),
              child: Text(
                '${_expandedSources.contains(turn.id) ? 'Hide' : 'Show'} sources (${turn.provenance.evidence.length})',
              ),
            ),
          ),
          if (_expandedSources.contains(turn.id))
            for (final source in turn.provenance.evidence)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: CupertinoColors.separator.resolveFrom(context),
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.sourceTitle,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      [
                        if (source.page != null) 'Page ${source.page}',
                        if (source.heading.isNotEmpty) source.heading,
                      ].join(' · '),
                      style: const TextStyle(fontSize: 13),
                    ),
                    SelectableText(source.passageText),
                    if (source.sourceDeleted)
                      const Text('Source deleted')
                    else
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => _openSource(source),
                        child: const Text('Open source'),
                      ),
                  ],
                ),
              ),
        ],
        if (turn.outcome != TurnOutcome.generating)
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => _actions(turn),
              child: const Icon(
                CupertinoIcons.ellipsis,
                semanticLabel: 'Turn actions',
              ),
            ),
          ),
      ],
    ),
  );

  String _status(TurnRecord turn) => switch (turn.outcome) {
    TurnOutcome.generating => 'Responding…',
    TurnOutcome.stopped => 'Stopped · Response incomplete',
    TurnOutcome.interrupted => 'Interrupted · Regenerate to try again',
    TurnOutcome.failed => switch (turn.failure) {
      TurnFailure.sourcesUnavailable =>
        'Selected sources are no longer ready. Check your Knowledge Base.',
      TurnFailure.retrievalUnavailable =>
        'Could not retrieve evidence. Retry when indexing is available.',
      TurnFailure.contextOverflow =>
        'This turn exceeds the model context. Try a shorter question or start a new chat.',
      TurnFailure.deviceNotEligible =>
        'This device does not support the on-device model.',
      TurnFailure.appleIntelligenceNotEnabled =>
        'Enable Apple Intelligence in Settings to answer.',
      TurnFailure.modelNotReady || TurnFailure.unavailable =>
        'The on-device model is not ready. Try again shortly.',
      TurnFailure.guardrailViolation =>
        'The on-device model could not answer this request.',
      _ => 'The response failed. Regenerate to try again.',
    },
    _ => '',
  };

  Widget _composer() => Container(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: CupertinoColors.separator.resolveFrom(context)),
      ),
    ),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy &&
            !_turns.any((turn) => turn.outcome == TurnOutcome.generating))
          const Text(
            'Another chat is responding. Stop it before sending.',
            style: TextStyle(fontSize: 13),
          ),
        AccessibleChoice<ChatMode>(
          value: _chat?.mode ?? ChatMode.general,
          labels: const {
            ChatMode.general: 'General',
            ChatMode.knowledgeBase: 'Knowledge Base',
          },
          onChanged: (mode) {
            _scope(mode, _chat?.selectedSourceIds ?? []);
          },
        ),
        if (_chat?.mode == ChatMode.knowledgeBase) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  onPressed: _chooseSources,
                  child: const Text('Select sources'),
                ),
                for (final id in _chat!.selectedSourceIds) _sourceChip(id),
              ],
            ),
          ),
          if (!_sourcesReady)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Select sources and wait until all are indexed.',
                style: TextStyle(fontSize: 13),
              ),
            ),
        ],
        if (_availability is! Available)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(switch (_availability) {
                DeviceNotEligible() =>
                  'On-device answers are unsupported on this device.',
                AppleIntelligenceNotEnabled() =>
                  'Enable Apple Intelligence to answer.',
                ModelNotReady() => 'The on-device model is not ready.',
                _ => 'Checking on-device model…',
              }, style: const TextStyle(fontSize: 13)),
              CupertinoButton(
                onPressed: _checkAvailability,
                child: const Text('Retry'),
              ),
              if (_availability is AppleIntelligenceNotEnabled &&
                  widget.onSettings != null)
                CupertinoButton(
                  onPressed: widget.onSettings,
                  child: const Text('Open Settings'),
                ),
            ],
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextFieldTapRegion(
                groupId: _messageFocus,
                // Dismiss on release so controls do not move before their tap
                // finishes. Unfocus only the composer, not selectable answers.
                onTapUpOutside: (_) => _messageFocus.unfocus(),
                child: CupertinoTextField(
                  controller: _input,
                  focusNode: _messageFocus,
                  groupId: _messageFocus,
                  placeholder: 'Message',
                  minLines: 1,
                  maxLines: 4,
                  enabled: _availability is Available,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  padding: const EdgeInsets.all(12),
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.all(10),
              onPressed: _busy
                  ? () async {
                      await widget.engine.stop();
                      if (mounted) setState(() {});
                    }
                  : _chat != null &&
                        _availability is Available &&
                        _sourcesReady &&
                        _input.text.trim().isNotEmpty
                  ? () => _send()
                  : null,
              child: Icon(
                _busy
                    ? CupertinoIcons.stop_circle
                    : CupertinoIcons.arrow_up_circle_fill,
                size: 30,
                semanticLabel: _busy ? 'Stop' : 'Send',
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _sourceChip(String id) {
    final item = _items.where((item) => item.id == id).firstOrNull;
    final status = item == null
        ? 'Source deleted'
        : processingLabel(item.processingState);
    return Semantics(
      label: '${item?.title ?? 'Source'} · $status',
      excludeSemantics: true,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .65,
        ),
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item != null)
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            Text(status, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
