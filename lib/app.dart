import 'package:flutter/material.dart';

import 'core/question/document_question_service.dart';
import 'core/platform/llm_backend.dart';
import 'demo/demo_dependencies.dart';
import 'demo/fictional_document.dart';

const _ink = Color(0xFF122033);
const _paper = Color(0xFFF4F6F8);
const _surface = Color(0xFFFFFFFF);
const _verificationBlue = Color(0xFF2864DC);
const _slate = Color(0xFF5C697A);
const _line = Color(0xFFDCE2E8);

final class SekretMidgetApp extends StatelessWidget {
  const SekretMidgetApp({
    super.key,
    this.modelAvailability = const Available(),
  });

  final LlmAvailability modelAvailability;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sekret Midget',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
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
      ),
      home: _DocumentDesk(modelAvailability: modelAvailability),
    );
  }
}

final class _DocumentDesk extends StatefulWidget {
  const _DocumentDesk({required this.modelAvailability});

  final LlmAvailability modelAvailability;

  @override
  State<_DocumentDesk> createState() => _DocumentDeskState();
}

final class _DocumentDeskState extends State<_DocumentDesk> {
  final _questionController = TextEditingController();
  late final _questionService = createDemoDocumentQuestionService(
    modelAvailability: widget.modelAvailability,
  );
  DocumentQuestionOutcome? _outcome;
  bool _isAsking = false;

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _askDocument() async {
    final question = _questionController.text.trim();
    if (question.isEmpty || _isAsking) {
      return;
    }
    setState(() {
      _isAsking = true;
      _outcome = null;
    });
    final outcome = await _questionService.ask(
      document: fictionalEmploymentAgreement,
      question: question,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isAsking = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Header(),
                    const SizedBox(height: 32),
                    const _DocumentCard(),
                    const SizedBox(height: 20),
                    if (widget.modelAvailability is Available)
                      _QuestionComposer(
                        controller: _questionController,
                        isAsking: _isAsking,
                        onAsk: _askDocument,
                      )
                    else
                      _AvailabilityCard(availability: widget.modelAvailability),
                    if (_outcome case final GroundedAnswer answer) ...[
                      const SizedBox(height: 20),
                      _GroundedAnswerCard(answer: answer),
                    ] else if (_outcome
                        case final InsufficientEvidence result) ...[
                      const SizedBox(height: 20),
                      _InsufficientEvidenceCard(message: result.message),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _AvailabilityCard extends StatelessWidget {
  const _AvailabilityCard({required this.availability});

  final LlmAvailability availability;

  @override
  Widget build(BuildContext context) {
    final (title, detail) = switch (availability) {
      DeviceNotEligible() => (
        'This device cannot run Apple Intelligence.',
        'On-device answers require an eligible iPhone.',
      ),
      AppleIntelligenceNotEnabled() => (
        'Apple Intelligence is turned off.',
        'Enable Apple Intelligence in Settings to ask this document.',
      ),
      ModelNotReady() => (
        'The on-device model is still getting ready.',
        'Keep the phone powered and try again after its model assets finish downloading.',
      ),
      Available() => ('The on-device model is ready.', ''),
    };

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E3),
        border: Border.all(color: const Color(0xFFE5C886)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: Color(0xFF8B5A00)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFF5C3A00),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  detail,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF725423),
                    height: 1.4,
                  ),
                ),
                if (availability is AppleIntelligenceNotEnabled) ...[
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'The iPhone build will open Apple Intelligence settings.',
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open Settings'),
                  ),
                ] else if (availability is ModelNotReady) ...[
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'The on-device model is not ready yet.',
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check again'),
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

final class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        const _LocalBadge(),
      ],
    );
  }
}

final class _LocalBadge extends StatelessWidget {
  const _LocalBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}

final class _DocumentCard extends StatelessWidget {
  const _DocumentCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.description_outlined, color: _verificationBlue),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'BUILT-IN DOCUMENT · FICTIONAL',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: _verificationBlue,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    fictionalEmploymentAgreement.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '2 indexed passages · compensation and termination',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: _slate),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _QuestionComposer extends StatelessWidget {
  const _QuestionComposer({
    required this.controller,
    required this.isAsking,
    required this.onAsk,
  });

  final TextEditingController controller;
  final bool isAsking;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Ask this document',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          minLines: 2,
          maxLines: 4,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onAsk(),
          decoration: const InputDecoration(
            hintText: 'How much notice is required to end employment?',
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
      ],
    );
  }
}

final class _GroundedAnswerCard extends StatelessWidget {
  const _GroundedAnswerCard({required this.answer});

  final GroundedAnswer answer;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
                    const SizedBox(height: 20),
                    const Divider(color: _line),
                    const SizedBox(height: 12),
                    Text(
                      '${answer.citation.heading} · Page ${answer.citation.page}',
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
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.search_off_rounded, color: _slate),
          const SizedBox(width: 14),
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
