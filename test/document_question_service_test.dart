import 'package:flutter_test/flutter_test.dart';
import 'package:sekret_midget/core/question/document_question_service.dart';
import 'package:sekret_midget/demo/demo_dependencies.dart';
import 'package:sekret_midget/demo/fictional_document.dart';

void main() {
  test(
    'an answerable question returns a grounded answer with its source',
    () async {
      final service = createDemoDocumentQuestionService();

      final outcome = await service.ask(
        document: fictionalEmploymentAgreement,
        question: 'How much notice is required to end employment?',
      );

      expect(
        outcome,
        isA<GroundedAnswer>()
            .having(
              (answer) => answer.text,
              'answer',
              "Either party must give at least 30 days' written notice.",
            )
            .having((answer) => answer.citation.page, 'source page', 8)
            .having(
              (answer) => answer.citation.heading,
              'source heading',
              '12. Termination',
            )
            .having(
              (answer) => answer.citation.passage,
              'source passage',
              contains("30 days' written notice"),
            ),
      );
    },
  );

  test(
    'an unsupported question returns the fixed insufficient-evidence response',
    () async {
      final service = createDemoDocumentQuestionService();

      final outcome = await service.ask(
        document: fictionalEmploymentAgreement,
        question: 'Does termination happen immediately when fraud is alleged?',
      );

      expect(
        outcome,
        isA<InsufficientEvidence>().having(
          (result) => result.message,
          'message',
          'I couldn’t find enough evidence in this document.',
        ),
      );
    },
  );
}
