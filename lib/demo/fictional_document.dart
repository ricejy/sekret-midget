import '../core/document/document.dart';

const fictionalEmploymentAgreement = Document(
  title: 'Northstar Workshop Employment Agreement',
  chunks: [
    DocumentChunk(
      heading: '4. Compensation',
      page: 3,
      text:
          'The employee receives a fictional annual salary of 84,000 aurums, '
          'paid in equal monthly installments.',
    ),
    DocumentChunk(
      heading: '12. Termination',
      page: 8,
      text:
          "Either party may end employment by giving at least 30 days' written "
          'notice to the other party. This fictional term does not apply to any '
          'real person or employment relationship.',
    ),
  ],
);
