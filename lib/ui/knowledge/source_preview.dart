import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:pdfrx/pdfrx.dart';
import '../../core/knowledge/knowledge_base.dart';
import '../../core/storage/local_data_vault.dart';
import '../chat/chat_sheets.dart' show processingLabel;
import '../accessible_controls.dart';

/// Shared catalogue/citation destination. Re-resolves changes rather than
/// keeping a navigable snapshot after another tab deletes the original.
class SourcePreview extends StatefulWidget {
  const SourcePreview({
    super.key,
    required this.knowledge,
    required this.location,
  });
  final KnowledgeBase knowledge;
  final KnowledgeLocation location;
  @override
  State<SourcePreview> createState() => _SourcePreviewState();
}

class _SourcePreviewState extends State<SourcePreview> {
  KnowledgePreview? _preview;
  bool _loaded = false;
  String? _error;
  bool _extracted = false;
  late int _page = widget.location.page ?? 1;
  final _query = TextEditingController();
  final _pdf = PdfViewerController();
  PdfTextSearcher? _pdfSearch;
  Future<void>? _pdfInitialization;
  StreamSubscription<void>? _changes;
  int _revision = 0;
  List<({int page, int start, int end})> _matches = [];
  int _match = 0;
  bool _locatePdfMatch = false;

  @override
  void initState() {
    super.initState();
    _query.text = widget.location.text ?? '';
    _changes = widget.knowledge.changes.listen(
      (_) => _load(),
      onError: (Object _) => _load(),
    );
    _load();
  }

  Future<void> _load() async {
    final revision = ++_revision;
    try {
      var preview = await widget.knowledge.preview(
        KnowledgeLocation(widget.location.itemId),
      );
      if (!mounted || revision != _revision) return;
      final previous = _preview;
      if (preview != null && previous != null) {
        // A knowledge item's original is immutable. Preserve its byte identity
        // so processing notifications don't reload PDF/image caches.
        preview = KnowledgePreview(
          item: preview.item,
          location: preview.location,
          source: KnowledgeSource(
            bytes: previous.source.bytes,
            pages: preview.source.pages,
          ),
        );
      } else if (preview == null) {
        _evictPhoto(previous);
      }
      setState(() {
        _preview = preview;
        _loaded = true;
        _error = null;
      });
      if (preview == null) {
        _pdfSearch?.dispose();
        _pdfSearch = null;
        _matches = [];
        _query.clear();
      } else {
        _search(jump: false);
      }
    } on Object {
      if (mounted && revision == _revision) {
        _evictPhoto(_preview);
        setState(() {
          _preview = null;
          _error = 'Preview could not be loaded. Try again.';
        });
      }
    }
  }

  void _evictPhoto(KnowledgePreview? preview) {
    if (preview?.item.sourceType == KnowledgeSourceType.photo) {
      unawaited(MemoryImage(preview!.source.bytes).evict());
    }
  }

  List<KnowledgePage> get _pages {
    final preview = _preview!;
    if (preview.item.sourceType == KnowledgeSourceType.pastedText &&
        !_extracted) {
      return [
        KnowledgePage(number: 1, text: utf8.decode(preview.source.bytes)),
      ];
    }
    return preview.source.pages;
  }

  void _search({bool jump = true}) {
    if (_preview == null) return;
    final needle = _query.text.trim().toLowerCase();
    final matches = <({int page, int start, int end})>[];
    if (needle.isNotEmpty) {
      for (final page in _pages) {
        final text = page.text.toLowerCase();
        var offset = 0;
        while (offset <= text.length - needle.length) {
          final start = text.indexOf(needle, offset);
          if (start < 0) break;
          matches.add((
            page: page.number,
            start: start,
            end: start + needle.length,
          ));
          offset = start + needle.length;
        }
      }
    }
    setState(() {
      _matches = matches;
      _match = jump
          ? 0
          : matches
                .indexWhere((m) => m.page == _page)
                .clamp(0, matches.isEmpty ? 0 : matches.length - 1);
      if (jump && matches.isNotEmpty) _page = matches.first.page;
    });
    _locatePdfMatch = true;
    _pdfSearch?.startTextSearch(_query.text.trim(), goToFirstMatch: false);
    if (jump) _goToPage(_page);
  }

  void _goToPage(int page) {
    setState(() => _page = page);
    if (_pdf.isReady && !_extracted) {
      unawaited(_pdf.goToPage(pageNumber: page, duration: Duration.zero));
    }
  }

  void _moveMatch(int delta) {
    setState(() => _match = (_match + delta).clamp(0, _matches.length - 1));
    _goToPage(_matches[_match].page);
    _locatePdfMatch = true;
    _pdfSearchChanged();
  }

  void _pdfSearchChanged() {
    final search = _pdfSearch;
    if (!mounted || search == null || !_locatePdfMatch || !_pdf.isReady) return;
    final pageMatches = search.matches
        .where((m) => m.pageNumber == _page)
        .toList();
    if (pageMatches.isEmpty) return;
    // Only native text geometry is highlighted. OCR locations never invent it.
    final ordinal = _matches.take(_match).where((m) => m.page == _page).length;
    _locatePdfMatch = false;
    final match = pageMatches[ordinal.clamp(0, pageMatches.length - 1)];
    if (MediaQuery.disableAnimationsOf(context)) {
      unawaited(
        _pdf.ensureVisible(
          _pdf.calcRectForRectInsidePage(
            pageNumber: match.pageNumber,
            rect: match.bounds,
          ),
          margin: 50,
          duration: Duration.zero,
        ),
      );
    } else {
      unawaited(search.goToMatch(match));
    }
  }

  void _info() {
    final preview = _preview!;
    final item = preview.item;
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Source information'),
        content: Text(
          '${item.title}\n${item.sourceName ?? 'Pasted text'}\n${item.sourceSize} bytes · ${item.pageCount} pages\nImported ${item.createdAt.toLocal()}\n${processingLabel(item.processingState)}'
          '${item.processingMessage == null ? '' : '\n${item.processingMessage}'}'
          '${preview.hasOcrWarning ? '\nSome recognized text has low confidence. Compare it with the original before relying on it.' : ''}'
          '${preview.source.pages.any((p) => p.ocrConfidence != null) ? '\nOCR search locates a page, not exact image coordinates. Select or copy recognized text in Extracted text.' : ''}'
          '\nRead-only. Stored on this device.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    _evictPhoto(_preview);
    _pdfSearch?.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final item = preview?.item;
    final pages = item == null
        ? 1
        : (_pdf.isReady ? _pdf.pageCount : item.pageCount).clamp(1, 1000000);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          item?.title ?? 'Preview',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: item == null
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _info,
                child: const Icon(
                  CupertinoIcons.info_circle,
                  semanticLabel: 'Source information',
                ),
              ),
      ),
      child: SafeArea(
        child: preview == null
            ? Center(
                child: _error != null
                    ? CupertinoButton(onPressed: _load, child: Text(_error!))
                    : _loaded
                    ? const Text('Source deleted')
                    : const CupertinoActivityIndicator(),
              )
            : PanelAndContent(
                panel: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: CupertinoSearchTextField(
                        controller: _query,
                        placeholder: 'Search this source',
                        onChanged: (_) => _search(),
                      ),
                    ),
                    if (item!.sourceType != KnowledgeSourceType.pastedText)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: AccessibleChoice<bool>(
                          value: _extracted,
                          labels: const {
                            false: 'Original',
                            true: 'Extracted text',
                          },
                          onChanged: (value) {
                            _pdfSearch?.dispose();
                            _pdfSearch = null;
                            setState(() => _extracted = value);
                            _search(jump: false);
                          },
                        ),
                      ),
                    if (_query.text.trim().isNotEmpty)
                      Row(
                        children: [
                          CupertinoButton(
                            onPressed: _matches.isNotEmpty && _match > 0
                                ? () => _moveMatch(-1)
                                : null,
                            child: const Icon(
                              CupertinoIcons.chevron_up,
                              semanticLabel: 'Previous match',
                            ),
                          ),
                          Expanded(
                            child: Text(
                              _matches.isEmpty
                                  ? 'No matches in available text'
                                  : '${_match + 1} of ${_matches.length} matches',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          CupertinoButton(
                            onPressed:
                                _matches.isNotEmpty &&
                                    _match < _matches.length - 1
                                ? () => _moveMatch(1)
                                : null,
                            child: const Icon(
                              CupertinoIcons.chevron_down,
                              semanticLabel: 'Next match',
                            ),
                          ),
                        ],
                      ),
                    if (widget.location.text?.isNotEmpty == true &&
                        _query.text == widget.location.text)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 90),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Captured passage',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SelectableText(
                                widget.location.text!,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (item.sourceType == KnowledgeSourceType.pdf)
                      _pageControls(pages),
                  ],
                ),
                content:
                    _extracted ||
                        item.sourceType == KnowledgeSourceType.pastedText
                    ? _textView()
                    : item.sourceType == KnowledgeSourceType.photo
                    ? InteractiveViewer(
                        minScale: .5,
                        maxScale: 5,
                        child: Center(
                          child: Image.memory(
                            preview.source.bytes,
                            gaplessPlayback: true,
                            semanticLabel: 'Original photograph',
                            errorBuilder: (_, _, _) => const Text(
                              'Image preview unavailable. Try Extracted text.',
                            ),
                          ),
                        ),
                      )
                    : FutureBuilder<void>(
                        future: _pdfInitialization ??= pdfrxFlutterInitialize(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return const Center(
                              child: Text(
                                'PDF preview unavailable. Try Extracted text.',
                              ),
                            );
                          }
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Center(
                              child: CupertinoActivityIndicator(),
                            );
                          }
                          return PdfViewer.data(
                            preview.source.bytes,
                            sourceName: item.title,
                            controller: _pdf,
                            initialPageNumber: _page,
                            params: PdfViewerParams(
                              backgroundColor: CupertinoColors.systemGrey6
                                  .resolveFrom(context),
                              textSelectionParams:
                                  const PdfTextSelectionParams(),
                              onViewerReady: (_, controller) {
                                _pdfSearch?.dispose();
                                _pdfSearch = PdfTextSearcher(controller)
                                  ..addListener(_pdfSearchChanged);
                                setState(() {});
                                _locatePdfMatch = true;
                                _pdfSearch!.startTextSearch(
                                  _query.text.trim(),
                                  goToFirstMatch: false,
                                );
                              },
                              onPageChanged: (page) {
                                if (mounted && page != null && page != _page) {
                                  setState(() => _page = page);
                                }
                              },
                              pagePaintCallbacks: [
                                if (_pdfSearch != null)
                                  _pdfSearch!.pageTextMatchPaintCallback,
                              ],
                              errorBannerBuilder: (_, _, _, _) => const Center(
                                child: Text(
                                  'PDF preview unavailable. Try Extracted text.',
                                ),
                              ),
                              // No link handler: a PDF never launches a URL implicitly.
                            ),
                          );
                        },
                      ),
              ),
      ),
    );
  }

  Widget _pageControls(int pages) => Row(
    children: [
      CupertinoButton(
        onPressed: _page > 1 ? () => _goToPage(_page - 1) : null,
        child: const Icon(
          CupertinoIcons.chevron_left,
          semanticLabel: 'Previous page',
        ),
      ),
      Expanded(
        child: Text(
          'Page $_page of $pages',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13),
        ),
      ),
      CupertinoButton(
        onPressed: _page < pages ? () => _goToPage(_page + 1) : null,
        child: const Icon(
          CupertinoIcons.chevron_right,
          semanticLabel: 'Next page',
        ),
      ),
    ],
  );

  Widget _textView() {
    final pages = _pages.where((p) => p.number == _page);
    final text = pages.isEmpty ? '' : pages.first.text;
    if (text.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Extracted text is not available for this page yet. Check processing status in Source information.',
          ),
        ),
      );
    }
    final match = _matches.isNotEmpty && _matches[_match].page == _page
        ? _matches[_match]
        : null;
    return _SelectableSourceText(
      text: text,
      start: match?.start,
      end: match?.end,
    );
  }
}

/// A read-only native text surface with a public scroll-to-selection API.
class _SelectableSourceText extends StatefulWidget {
  const _SelectableSourceText({required this.text, this.start, this.end});
  final String text;
  final int? start;
  final int? end;
  @override
  State<_SelectableSourceText> createState() => _SelectableSourceTextState();
}

class _SelectableSourceTextState extends State<_SelectableSourceText>
    implements TextSelectionGestureDetectorBuilderDelegate {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _editable = GlobalKey<EditableTextState>();
  late final _gestures = TextSelectionGestureDetectorBuilder(delegate: this);
  @override
  GlobalKey<EditableTextState> get editableTextKey => _editable;
  @override
  bool get forcePressEnabled => false;
  @override
  bool get selectionEnabled => true;
  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(covariant _SelectableSourceText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.start != widget.start ||
        oldWidget.end != widget.end) {
      _update();
    }
  }

  void _update() {
    _controller.value = TextEditingValue(
      text: widget.text,
      selection: widget.start == null
          ? const TextSelection.collapsed(offset: 0)
          : TextSelection(baseOffset: widget.start!, extentOffset: widget.end!),
    );
    if (widget.start != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.start != null) {
          _editable.currentState?.bringIntoView(
            TextPosition(offset: widget.start!),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: _gestures.buildGestureDetector(
      behavior: HitTestBehavior.translucent,
      child: EditableText(
        key: _editable,
        rendererIgnoresPointer: true,
        controller: _controller,
        focusNode: _focus,
        readOnly: true,
        showCursor: false,
        maxLines: null,
        expands: true,
        style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
          color: CupertinoColors.label.resolveFrom(context),
        ),
        cursorColor: CupertinoColors.systemBlue.resolveFrom(context),
        backgroundCursorColor: CupertinoColors.systemGrey,
        selectionColor: CupertinoColors.systemBlue
            .resolveFrom(context)
            .withValues(alpha: .22),
        selectionControls: cupertinoTextSelectionHandleControls,
        contextMenuBuilder: (context, state) =>
            CupertinoAdaptiveTextSelectionToolbar.editableText(
              editableTextState: state,
            ),
      ),
    ),
  );
}
