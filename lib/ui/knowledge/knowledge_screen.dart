import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/knowledge/knowledge_base.dart';
import '../../core/storage/local_data_vault.dart';
import '../../core/platform/pdf_file_picker.dart';
import '../../core/platform/document_image_picker.dart';
import '../../core/platform/file_selector_pdf_picker.dart';
import '../../core/platform/file_selector_document_image_picker.dart';
import '../chat/chat_sheets.dart' show processingLabel;
import 'source_preview.dart';
import 'import_sheet.dart';
import 'rename_sheet.dart';

String sourceTypeLabel(KnowledgeSourceType type) => switch (type) {
  KnowledgeSourceType.pastedText => 'Text',
  KnowledgeSourceType.pdf => 'PDF',
  KnowledgeSourceType.photo => 'Photo',
};

String sourceSizeLabel(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String importDateLabel(DateTime date) {
  final local = date.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

class KnowledgeScreen extends StatefulWidget {
  const KnowledgeScreen({
    super.key,
    required this.knowledge,
    this.pdfPicker = const FileSelectorPdfPicker(),
    this.imagePicker = const FileSelectorDocumentImagePicker(),
  });
  final KnowledgeBase knowledge;
  final PdfFilePicker pdfPicker;
  final DocumentImagePicker imagePicker;
  @override
  State<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

class _KnowledgeScreenState extends State<KnowledgeScreen> {
  final _search = TextEditingController();
  StreamSubscription<void>? _changes;
  List<CatalogueMatch>? _matches;
  KnowledgeSourceType? _type;
  KnowledgeProcessingState? _state;
  String? _error;
  String? _loadError;
  Timer? _debounce;
  int _revision = 0;
  bool _importing = false;
  final _busy = <String>{};

  void _startProcessing(String id) {
    // KnowledgeBase owns the long-running job. Do not disable Cancel/Delete
    // for its entire duration; those actions coordinate a safe stop themselves.
    unawaited(
      widget.knowledge
          .process(id)
          .then<void>(
            (_) {},
            onError: (Object _) {
              if (mounted) {
                setState(
                  () => _error =
                      'Indexing could not finish. Retry from the source actions.',
                );
              }
            },
          ),
    );
  }

  Future<void> _perform(
    KnowledgeItemRecord item,
    Future<void> Function() action,
  ) async {
    if (_busy.contains(item.id)) return;
    setState(() {
      _busy.add(item.id);
      _error = null;
    });
    try {
      await action();
    } on Object {
      if (mounted) {
        setState(
          () => _error = 'The action could not finish. Refresh and try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(item.id));
        await _load();
      }
    }
  }

  Future<void> _rename(KnowledgeItemRecord item) async {
    final title = await showCupertinoDialog<String>(
      context: context,
      builder: (_) => RenameKnowledge(title: item.title),
    );
    if (mounted && title != null) {
      await _perform(item, () => widget.knowledge.rename(item.id, title));
    }
  }

  Future<void> _delete(KnowledgeItemRecord item, {bool cancel = false}) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(
          cancel ? 'Discard incomplete import?' : 'Delete “${item.title}”?',
        ),
        content: Text(
          cancel
              ? 'The original source and all processing work will be permanently removed. If indexing has just finished, use Delete source instead.'
              : 'The source, extracted text, and search index will be permanently removed. Chat text remains and may contain sensitive information derived from this source. Its citations will show Source deleted.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(cancel ? 'Discard import' : 'Delete permanently'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _perform(
        item,
        () => cancel
            ? widget.knowledge.cancelImport(item.id)
            : widget.knowledge.delete(item.id),
      );
    }
  }

  Future<void> _actions(KnowledgeItemRecord item) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(item.title),
        message: Text(
          item.processingMessage ?? processingLabel(item.processingState),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'rename'),
            child: const Text('Rename'),
          ),
          if (item.processingState == KnowledgeProcessingState.indexed)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'reindex'),
              child: const Text('Re-index'),
            ),
          if (item.processingState == KnowledgeProcessingState.paused ||
              item.processingState == KnowledgeProcessingState.failed ||
              item.processingState == KnowledgeProcessingState.needsReindexing)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, 'retry'),
              child: const Text('Retry indexing'),
            ),
          if (item.processingState != KnowledgeProcessingState.indexed)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel import'),
            ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, 'delete'),
            child: const Text('Delete source'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        await _rename(item);
      case 'delete':
        await _delete(item);
      case 'cancel':
        await _delete(item, cancel: true);
      case 'retry':
        _startProcessing(item.id);
      case 'reindex':
        final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Re-index this source?'),
            content: const Text(
              'The original stays available. This source cannot support new answers until indexing finishes.',
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Re-index'),
              ),
            ],
          ),
        );
        if (mounted && confirmed == true) {
          await _perform(item, () async {
            await widget.knowledge.invalidateIndex(item.id);
            _startProcessing(item.id);
          });
        }
    }
  }

  Future<void> _open(KnowledgeLocation location) async {
    try {
      final preview = await widget.knowledge.preview(location);
      if (!mounted) return;
      if (preview == null) {
        setState(() => _error = 'Source deleted.');
        return;
      }
      await Navigator.of(context).push<void>(
        CupertinoPageRoute(
          builder: (_) =>
              SourcePreview(knowledge: widget.knowledge, location: location),
        ),
      );
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not open this source. Try again.');
      }
    }
  }

  Future<void> _add() async {
    if (_importing) return;
    final type = await showCupertinoModalPopup<KnowledgeSourceType>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Add to Knowledge Base'),
        message: const Text('Your source stays on this device.'),
        actions: [
          for (final type in KnowledgeSourceType.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, type),
              child: Text(switch (type) {
                KnowledgeSourceType.pastedText => 'Paste text',
                KnowledgeSourceType.pdf => 'Choose PDF',
                KnowledgeSourceType.photo => 'Choose photograph',
              }),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (!mounted || type == null) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      KnowledgeImportResult? result;
      switch (type) {
        case KnowledgeSourceType.pastedText:
          result = await Navigator.of(context).push<KnowledgeImportResult>(
            CupertinoPageRoute(
              fullscreenDialog: true,
              builder: (_) => PasteKnowledge(knowledge: widget.knowledge),
            ),
          );
        case KnowledgeSourceType.pdf:
          final picked = await widget.pdfPicker.pickPdf();
          if (!mounted || picked == null) return;
          result = await widget.knowledge.importSource(
            title: picked.name,
            sourceName: picked.name,
            sourceType: type,
            bytes: picked.bytes,
          );
        case KnowledgeSourceType.photo:
          final picked = await widget.imagePicker.pickImage();
          if (!mounted || picked == null) return;
          result = await widget.knowledge.importSource(
            title: picked.name,
            sourceName: picked.name,
            sourceType: type,
            bytes: picked.bytes,
          );
      }
      if (!mounted || result == null) return;
      if (result.duplicate) {
        final open = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Already in your Knowledge Base'),
            content: Text(
              'This content is already saved as “${result!.item.title}”. No second copy was added.',
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep existing'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Open existing'),
              ),
            ],
          ),
        );
        if (mounted && open == true) {
          await _open(KnowledgeLocation(result.item.id));
        }
      } else {
        // An active filter must not hide the item that was just admitted.
        _search.clear();
        _type = null;
        _state = null;
        await _load();
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Import could not finish. Check the source and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _changes = widget.knowledge.changes.listen(
      (_) => _load(),
      onError: (Object _) => _load(),
    );
    _load();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      final matches = await widget.knowledge.catalogue(
        query: _search.text,
        sourceType: _type,
        state: _state,
      );
      if (mounted && revision == _revision) {
        setState(() {
          _matches = matches;
          _loadError = null;
        });
      }
    } on Object {
      if (mounted && revision == _revision) {
        setState(
          () => _loadError = 'Could not load the Knowledge Base. Try again.',
        );
      }
    }
  }

  Future<void> _filter({required bool types}) async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(types ? 'Source type' : 'Processing state'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              setState(() {
                if (types) {
                  _type = null;
                } else {
                  _state = null;
                }
              });
              Navigator.pop(context);
              _load();
            },
            child: Text(types ? 'All types' : 'All states'),
          ),
          if (types)
            for (final type in KnowledgeSourceType.values)
              CupertinoActionSheetAction(
                onPressed: () {
                  setState(() => _type = type);
                  Navigator.pop(context);
                  _load();
                },
                child: Text(sourceTypeLabel(type)),
              )
          else
            for (final state in KnowledgeProcessingState.values)
              CupertinoActionSheetAction(
                onPressed: () {
                  setState(() => _state = state);
                  Navigator.pop(context);
                  _load();
                },
                child: Text(processingLabel(state)),
              ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: const Text('Knowledge Base'),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _importing ? null : _add,
        child: const Icon(CupertinoIcons.add, semanticLabel: 'Add knowledge'),
      ),
    ),
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: CupertinoSearchTextField(
              controller: _search,
              placeholder: 'Search knowledge',
              onChanged: (_) {
                ++_revision;
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 180), _load);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              children: [
                CupertinoButton(
                  onPressed: () => _filter(types: true),
                  child: Text(
                    _type == null ? 'All types' : sourceTypeLabel(_type!),
                  ),
                ),
                CupertinoButton(
                  onPressed: () => _filter(types: false),
                  child: Text(
                    _state == null ? 'All states' : processingLabel(_state!),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null || _loadError != null)
            CupertinoButton(
              onPressed: () {
                setState(() => _error = null);
                _load();
              },
              child: Text(_error ?? _loadError!),
            ),
          if (_matches != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_matches!.length} ${_matches!.length == 1 ? 'item' : 'items'}',
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ),
          Expanded(
            child: _matches == null
                ? const Center(child: CupertinoActivityIndicator())
                : _matches!.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _search.text.isNotEmpty ||
                                _type != null ||
                                _state != null
                            ? 'No matching items'
                            : 'Your knowledge, on device.\nAdd text, a PDF, or a photograph to get started.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _matches!.length,
                    itemBuilder: (context, index) {
                      final match = _matches![index];
                      final item = match.item;
                      final date = importDateLabel(item.createdAt);
                      final checkpoint = item.checkpoint;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (index == 0 ||
                              importDateLabel(
                                    _matches![index - 1].item.createdAt,
                                  ) !=
                                  date)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                              child: Text(
                                date,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                              ),
                            ),
                          Dismissible(
                            key: ValueKey(item.id),
                            confirmDismiss: (direction) async {
                              if (!_busy.contains(item.id)) {
                                if (direction == DismissDirection.startToEnd) {
                                  await _rename(item);
                                } else {
                                  await _delete(item);
                                }
                              }
                              return false;
                            },
                            background: Container(
                              color: CupertinoColors.systemBlue,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.all(20),
                              child: const Text(
                                'Rename',
                                style: TextStyle(color: CupertinoColors.white),
                              ),
                            ),
                            secondaryBackground: Container(
                              color: CupertinoColors.systemRed,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.all(20),
                              child: const Text(
                                'Delete',
                                style: TextStyle(color: CupertinoColors.white),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: CupertinoButton(
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 12,
                                    ),
                                    onPressed: () => _open(
                                      match.location ??
                                          KnowledgeLocation(item.id),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.title,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: CupertinoColors.label
                                                .resolveFrom(context),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${sourceTypeLabel(item.sourceType)} · ${sourceSizeLabel(item.sourceSize)}${item.pageCount > 0 ? ' · ${item.pageCount} ${item.pageCount == 1 ? 'page' : 'pages'}' : ''}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: CupertinoColors
                                                .secondaryLabel
                                                .resolveFrom(context),
                                          ),
                                        ),
                                        Text(
                                          '${processingLabel(item.processingState)}${checkpoint == null ? '' : ' · ${checkpoint.stage} ${checkpoint.completedUnits}/${checkpoint.totalUnits}'}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: CupertinoColors.label
                                                .resolveFrom(context),
                                          ),
                                        ),
                                        if (item.processingMessage != null)
                                          Text(
                                            item.processingMessage!,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: CupertinoColors
                                                  .secondaryLabel
                                                  .resolveFrom(context),
                                            ),
                                          ),
                                        if (match.excerpt != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                            ),
                                            child: Text(
                                              match.excerpt!,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                CupertinoButton(
                                  onPressed: _busy.contains(item.id)
                                      ? null
                                      : () => _actions(item),
                                  child: Icon(
                                    CupertinoIcons.ellipsis,
                                    semanticLabel: 'Actions for ${item.title}',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            height: .5,
                            margin: const EdgeInsets.only(left: 20),
                            color: CupertinoColors.separator.resolveFrom(
                              context,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
