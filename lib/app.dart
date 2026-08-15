import 'dart:async';

import 'package:flutter/material.dart';

import 'core/library/document_library.dart';
import 'core/platform/llm_backend.dart';
import 'core/question/document_question_service.dart';
import 'demo/fake_native_capabilities.dart';

const _ink = Color(0xFF122033);
const _paper = Color(0xFFF4F6F8);
const _surface = Color(0xFFFFFFFF);
const _verificationBlue = Color(0xFF2864DC);
const _slate = Color(0xFF5C697A);
const _line = Color(0xFFDCE2E8);
const _warningSurface = Color(0xFFFFF6E3);
const _warningInk = Color(0xFF6B4708);

final class SekretMidgetApp extends StatefulWidget {
  const SekretMidgetApp({
    super.key,
    this.documentLibrary,
    this.documentLibraryFuture,
    this.modelAvailability = const Available(),
  }) : assert(
         documentLibrary == null || documentLibraryFuture == null,
         'Provide either documentLibrary or documentLibraryFuture, not both.',
       );

  final DocumentLibrary? documentLibrary;
  final Future<DocumentLibrary>? documentLibraryFuture;
  final LlmAvailability modelAvailability;

  @override
  State<SekretMidgetApp> createState() => _SekretMidgetAppState();
}

final class _SekretMidgetAppState extends State<SekretMidgetApp> {
  late final Future<DocumentLibrary> _libraryFuture;
  DocumentLibrary? _ownedLibrary;

  @override
  void initState() {
    super.initState();
    _libraryFuture = _resolveLibrary();
  }

  Future<DocumentLibrary> _resolveLibrary() async {
    if (widget.documentLibrary case final library?) {
      return library;
    }
    if (widget.documentLibraryFuture case final libraryFuture?) {
      final library = await libraryFuture;
      _ownedLibrary = library;
      return library;
    }
    final library = await openDocumentLibrary(
      databasePath: ':memory:',
      embedder: const FakeEmbedder(),
      llmBackend: FakeLlmBackend(modelAvailability: widget.modelAvailability),
      tokenCounter: const FakeTokenCounter(),
    );
    _ownedLibrary = library;
    return library;
  }

  @override
  void dispose() {
    if (_ownedLibrary case final library?) {
      unawaited(library.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sekret Midget',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: FutureBuilder<DocumentLibrary>(
        future: _libraryFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const _StartupFailure();
          }
          if (snapshot.data case final library?) {
            return _DocumentDesk(
              documentLibrary: library,
              modelAvailability: widget.modelAvailability,
            );
          }
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        },
      ),
    );
  }
}

ThemeData _theme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: _paper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _verificationBlue,
      brightness: Brightness.light,
      surface: _surface,
    ),
    textTheme: ThemeData.light().textTheme.apply(
      bodyColor: _ink,
      displayColor: _ink,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: _surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: _line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: _line),
      ),
    ),
  );
}

final class _StartupFailure extends StatelessWidget {
  const _StartupFailure();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('The private document library could not be opened.'),
        ),
      ),
    );
  }
}

final class _DocumentDesk extends StatefulWidget {
  const _DocumentDesk({
    required this.documentLibrary,
    required this.modelAvailability,
  });

  final DocumentLibrary documentLibrary;
  final LlmAvailability modelAvailability;

  @override
  State<_DocumentDesk> createState() => _DocumentDeskState();
}

final class _DocumentDeskState extends State<_DocumentDesk> {
  final _importTitleController = TextEditingController();
  final _importTextController = TextEditingController();
  final _questionController = TextEditingController();
  List<LibraryDocument> _documents = const [];
  LibraryDocument? _selectedDocument;
  DocumentQuestionOutcome? _outcome;
  ImportStage? _currentImportStage;
  List<ImportStage> _completedImportStages = const [];
  String? _importMessage;
  bool _showImport = false;
  bool _isImporting = false;
  bool _isAsking = false;
  bool _isLoadingLibrary = true;
  int _answerRequestId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDocuments());
  }

  @override
  void dispose() {
    _importTitleController.dispose();
    _importTextController.dispose();
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _loadDocuments() async {
    final documents = await widget.documentLibrary.listDocuments();
    if (!mounted) {
      return;
    }
    setState(() {
      _documents = documents;
      _isLoadingLibrary = false;
      if (_selectedDocument != null &&
          !documents.any((document) => document.id == _selectedDocument!.id)) {
        _selectedDocument = null;
      }
    });
  }

  void _openImport() {
    setState(() {
      _answerRequestId += 1;
      _showImport = true;
      _selectedDocument = null;
      _outcome = null;
      _isAsking = false;
      _importMessage = null;
      _completedImportStages = const [];
      _currentImportStage = null;
    });
  }

  Future<void> _importDocument() async {
    if (_isImporting) {
      return;
    }
    setState(() {
      _isImporting = true;
      _importMessage = null;
      _completedImportStages = const [];
    });
    final completed = <ImportStage>[];
    await for (final progress in widget.documentLibrary.importPastedText(
      title: _importTitleController.text,
      text: _importTextController.text,
    )) {
      if (!mounted) {
        return;
      }
      final completedStage = switch (progress.stage) {
        ImportStage.chunking => ImportStage.extracting,
        ImportStage.embedding => ImportStage.chunking,
        ImportStage.indexing => ImportStage.embedding,
        ImportStage.complete => ImportStage.indexing,
        ImportStage.extracting || ImportStage.failed => null,
      };
      if (completedStage != null && !completed.contains(completedStage)) {
        completed.add(completedStage);
      }
      setState(() {
        _currentImportStage = progress.stage;
        _completedImportStages = List.unmodifiable(completed);
        _importMessage = progress.message;
      });
      if (progress.stage == ImportStage.complete) {
        await _loadDocuments();
        if (!mounted) {
          return;
        }
        setState(() {
          _importMessage =
              'Import complete. Select the document from your library.';
        });
      }
    }
    if (mounted) {
      setState(() => _isImporting = false);
    }
  }

  void _selectDocument(LibraryDocument document) {
    setState(() {
      _answerRequestId += 1;
      _selectedDocument = document;
      _showImport = false;
      _outcome = null;
      _isAsking = false;
      _questionController.clear();
    });
  }

  Future<void> _askDocument() async {
    final document = _selectedDocument;
    final question = _questionController.text.trim();
    if (document == null || question.isEmpty || _isAsking) {
      return;
    }
    final requestId = ++_answerRequestId;
    setState(() {
      _isAsking = true;
      _outcome = null;
    });
    final outcome = await widget.documentLibrary.ask(
      documentId: document.id,
      question: question,
    );
    if (!mounted || requestId != _answerRequestId) {
      return;
    }
    if (_selectedDocument?.id != document.id ||
        _questionController.text.trim() != question) {
      setState(() => _isAsking = false);
      return;
    }
    setState(() {
      _isAsking = false;
      _outcome = outcome;
    });
  }

  Future<void> _confirmDelete(LibraryDocument document) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this document?'),
        content: Text(
          '“${document.title}” and all of its local search data will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete document'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) {
      return;
    }
    await widget.documentLibrary.deleteDocument(document.id);
    if (!mounted) {
      return;
    }
    setState(() {
      if (_selectedDocument?.id == document.id) {
        _answerRequestId += 1;
        _selectedDocument = null;
        _outcome = null;
        _isAsking = false;
      }
    });
    await _loadDocuments();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, 18),
              child: _Header(),
            ),
            const Divider(height: 1, color: _line),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final library = _LibraryPane(
                    documents: _documents,
                    selectedDocument: _selectedDocument,
                    isLoading: _isLoadingLibrary,
                    onImport: _openImport,
                    onSelect: _selectDocument,
                    onDelete: _confirmDelete,
                  );
                  final workspace = _buildWorkspace();
                  if (constraints.maxWidth >= 780) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 294, child: library),
                        const VerticalDivider(width: 1, color: _line),
                        Expanded(child: workspace),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      SizedBox(height: 270, child: library),
                      const Divider(height: 1, color: _line),
                      Expanded(child: workspace),
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

  Widget _buildWorkspace() {
    if (_showImport) {
      return _ImportWorkspace(
        titleController: _importTitleController,
        textController: _importTextController,
        completedStages: _completedImportStages,
        currentStage: _currentImportStage,
        message: _importMessage,
        isImporting: _isImporting,
        onImport: _importDocument,
      );
    }
    if (_selectedDocument case final document?) {
      if (widget.modelAvailability is! Available) {
        return _AvailabilityWorkspace(
          availability: widget.modelAvailability,
          document: document,
        );
      }
      return _QuestionWorkspace(
        document: document,
        questionController: _questionController,
        isAsking: _isAsking,
        outcome: _outcome,
        onAsk: _askDocument,
      );
    }
    return _NoSelectionWorkspace(hasDocuments: _documents.isNotEmpty);
  }
}

final class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.lock_outline_rounded, color: Colors.white),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SEKRET MIDGET',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Private evidence, answered locally.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: _slate),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFFE5F5EC),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            'LOCAL ONLY',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFF17613C),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
        ),
      ],
    );
  }
}

final class _LibraryPane extends StatelessWidget {
  const _LibraryPane({
    required this.documents,
    required this.selectedDocument,
    required this.isLoading,
    required this.onImport,
    required this.onSelect,
    required this.onDelete,
  });

  final List<LibraryDocument> documents;
  final LibraryDocument? selectedDocument;
  final bool isLoading;
  final VoidCallback onImport;
  final ValueChanged<LibraryDocument> onSelect;
  final ValueChanged<LibraryDocument> onDelete;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF8FAFC),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Your library',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Import pasted text',
                  onPressed: onImport,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isLoading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (documents.isEmpty)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.folder_open_rounded,
                      color: _slate,
                      size: 32,
                    ),
                    const SizedBox(height: 10),
                    const Text('No documents yet'),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: onImport,
                      icon: const Icon(Icons.content_paste_rounded),
                      label: const Text('Import pasted text'),
                    ),
                  ],
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: documents.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final document = documents[index];
                    final selected = selectedDocument?.id == document.id;
                    return Material(
                      color: selected
                          ? const Color(0xFFE8F0FF)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onSelect(document),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
                          child: Row(
                            children: [
                              Icon(
                                Icons.description_outlined,
                                color: selected ? _verificationBlue : _slate,
                                size: 20,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  document.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _ink,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Delete ${document.title}',
                                onPressed: () => onDelete(document),
                                icon: const Icon(Icons.delete_outline_rounded),
                                iconSize: 19,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _NoSelectionWorkspace extends StatelessWidget {
  const _NoSelectionWorkspace({required this.hasDocuments});

  final bool hasDocuments;

  @override
  Widget build(BuildContext context) {
    return _WorkspaceFrame(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fact_check_outlined, size: 40, color: _slate),
              const SizedBox(height: 14),
              Text(
                hasDocuments
                    ? 'Select one document to ask a question.'
                    : 'Import a document to begin.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Answers use evidence from only the document you select.',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: _slate, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ImportWorkspace extends StatelessWidget {
  const _ImportWorkspace({
    required this.titleController,
    required this.textController,
    required this.completedStages,
    required this.currentStage,
    required this.message,
    required this.isImporting,
    required this.onImport,
  });

  final TextEditingController titleController;
  final TextEditingController textController;
  final List<ImportStage> completedStages;
  final ImportStage? currentStage;
  final String? message;
  final bool isImporting;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return _WorkspaceFrame(
      child: ListView(
        children: [
          Text(
            'Paste a private document',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          Text(
            'The text is chunked, embedded, and indexed only in this local library.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _slate, height: 1.45),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const Key('import-title'),
            controller: titleController,
            enabled: !isImporting,
            decoration: const InputDecoration(labelText: 'Document title'),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('import-text'),
            controller: textController,
            enabled: !isImporting,
            minLines: 8,
            maxLines: 18,
            decoration: const InputDecoration(
              labelText: 'Document text',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: isImporting ? null : onImport,
              icon: isImporting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_outline_rounded),
              label: Text(
                isImporting ? 'Importing locally' : 'Import document',
              ),
            ),
          ),
          if (currentStage != null || message != null) ...[
            const SizedBox(height: 22),
            _ImportLedger(
              completedStages: completedStages,
              currentStage: currentStage,
              message: message,
            ),
          ],
        ],
      ),
    );
  }
}

final class _ImportLedger extends StatelessWidget {
  const _ImportLedger({
    required this.completedStages,
    required this.currentStage,
    required this.message,
  });

  final List<ImportStage> completedStages;
  final ImportStage? currentStage;
  final String? message;

  @override
  Widget build(BuildContext context) {
    const stages = [
      (ImportStage.extracting, 'Extracted'),
      (ImportStage.chunking, 'Chunked'),
      (ImportStage.embedding, 'Embedded'),
      (ImportStage.indexing, 'Indexed'),
    ];
    final failed = currentStage == ImportStage.failed;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: failed ? _warningSurface : const Color(0xFFF1F6FF),
        border: Border.all(
          color: failed ? const Color(0xFFE5C886) : const Color(0xFFC9D9F5),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (stage, label) in stages)
                _StageChip(
                  label: label,
                  complete: completedStages.contains(stage),
                ),
            ],
          ),
          if (message case final text?) ...[
            const SizedBox(height: 13),
            Text(
              text,
              style: TextStyle(
                color: failed ? _warningInk : _slate,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _StageChip extends StatelessWidget {
  const _StageChip({required this.label, required this.complete});

  final String label;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label ${complete ? 'complete' : 'pending'}',
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: complete ? const Color(0xFFE4F3EA) : _surface,
          border: Border.all(color: complete ? const Color(0xFF9CCBAF) : _line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              complete ? Icons.check_rounded : Icons.more_horiz_rounded,
              size: 15,
              color: complete ? const Color(0xFF17613C) : _slate,
            ),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

final class _QuestionWorkspace extends StatelessWidget {
  const _QuestionWorkspace({
    required this.document,
    required this.questionController,
    required this.isAsking,
    required this.outcome,
    required this.onAsk,
  });

  final LibraryDocument document;
  final TextEditingController questionController;
  final bool isAsking;
  final DocumentQuestionOutcome? outcome;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    return _WorkspaceFrame(
      child: ListView(
        children: [
          Text(
            'SELECTED DOCUMENT',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: _verificationBlue,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            document.title,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 22),
          TextField(
            key: const Key('question-field'),
            controller: questionController,
            minLines: 2,
            maxLines: 4,
            onSubmitted: (_) => onAsk(),
            decoration: const InputDecoration(
              labelText: 'Ask this document',
              hintText: 'What does the document say?',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: isAsking ? null : onAsk,
              icon: isAsking
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward_rounded),
              label: Text(isAsking ? 'Checking evidence' : 'Ask document'),
            ),
          ),
          if (outcome case final GroundedAnswer answer) ...[
            const SizedBox(height: 22),
            _GroundedAnswerCard(answer: answer),
          ] else if (outcome case final InsufficientEvidence result) ...[
            const SizedBox(height: 22),
            _InsufficientEvidenceCard(message: result.message),
          ],
        ],
      ),
    );
  }
}

final class _GroundedAnswerCard extends StatelessWidget {
  const _GroundedAnswerCard({required this.answer});

  final GroundedAnswer answer;

  @override
  Widget build(BuildContext context) {
    final sourceLabel = answer.citation.page > 0
        ? '${answer.citation.heading} · Page ${answer.citation.page}'
        : answer.citation.heading;
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 5,
              decoration: const BoxDecoration(
                color: _verificationBlue,
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(16),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GROUNDED ANSWER',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: _verificationBlue,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      answer.text,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(height: 1.25, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 18),
                    const Divider(color: _line),
                    const SizedBox(height: 10),
                    Text(
                      sourceLabel,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: _verificationBlue,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      answer.citation.passage,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _slate,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _InsufficientEvidenceCard extends StatelessWidget {
  const _InsufficientEvidenceCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_off_rounded, color: _slate),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

final class _AvailabilityWorkspace extends StatelessWidget {
  const _AvailabilityWorkspace({
    required this.availability,
    required this.document,
  });

  final LlmAvailability availability;
  final LibraryDocument document;

  @override
  Widget build(BuildContext context) {
    final (title, detail, action) = switch (availability) {
      DeviceNotEligible() => (
        'This device cannot run Apple Intelligence.',
        'On-device answers require an eligible iPhone.',
        null,
      ),
      AppleIntelligenceNotEnabled() => (
        'Apple Intelligence is turned off.',
        'Enable Apple Intelligence in Settings to ask this document.',
        'Open Settings',
      ),
      ModelNotReady() => (
        'The on-device model is still getting ready.',
        'Keep the phone powered and try again after its model assets finish downloading.',
        'Check again',
      ),
      Available() => ('The on-device model is ready.', '', null),
    };
    return _WorkspaceFrame(
      child: ListView(
        children: [
          Text(
            document.title,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _warningSurface,
              border: Border.all(color: const Color(0xFFE5C886)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _warningInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(detail, style: const TextStyle(color: _warningInk)),
                if (action case final label?) ...[
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('$label is fake-backed in this slice.'),
                        ),
                      );
                    },
                    child: Text(label),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _WorkspaceFrame extends StatelessWidget {
  const _WorkspaceFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 420),
        child: child,
      ),
    );
  }
}
