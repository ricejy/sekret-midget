final class SyntheticRetrievalDocument {
  const SyntheticRetrievalDocument({
    required this.id,
    required this.title,
    required this.text,
    required this.questions,
  });

  final String id;
  final String title;
  final String text;
  final List<SyntheticRetrievalQuestion> questions;
}

final class SyntheticRetrievalQuestion {
  const SyntheticRetrievalQuestion({
    required this.id,
    required this.category,
    required this.question,
    required this.relevantHeadings,
  });

  final String id;
  final String category;
  final String question;
  final Set<String> relevantHeadings;
}

/// Entirely fictional evaluation material written for this repository.
///
/// No passage, identifier, question, or expected result is derived from a real
/// person or document.
const syntheticRetrievalCorpus = <SyntheticRetrievalDocument>[
  SyntheticRetrievalDocument(
    id: 'synthetic-doc-01',
    title: 'Fictional Aster Employment Agreement',
    text: '''
NOTICE PERIOD

Either fictional party may end employment by providing forty-five calendar days of written notice.

COMPENSATION DATE

The fictional monthly salary is paid on the tenth business day of each month.

PERSONAL LEAVE

Each fictional employee receives seven personal leave days during every agreement year.

CONFIDENTIALITY

Unpublished prototype names and workshop access diagrams must remain confidential after employment ends.

EQUIPMENT RETURN

Borrowed devices must be returned to the Aster Workshop custodian by noon on the final working day.
''',
    questions: [
      SyntheticRetrievalQuestion(
        id: 'aster-notice',
        category: 'deadline',
        question: 'How much advance warning is needed to end the job?',
        relevantHeadings: {'NOTICE PERIOD'},
      ),
      SyntheticRetrievalQuestion(
        id: 'aster-pay-date',
        category: 'exact-term',
        question: 'On what business day is the monthly salary paid?',
        relevantHeadings: {'COMPENSATION DATE'},
      ),
      SyntheticRetrievalQuestion(
        id: 'aster-leave',
        category: 'amount',
        question: 'How many personal leave days are available each year?',
        relevantHeadings: {'PERSONAL LEAVE'},
      ),
      SyntheticRetrievalQuestion(
        id: 'aster-secrets',
        category: 'obligation',
        question: 'What information must stay secret after the job ends?',
        relevantHeadings: {'CONFIDENTIALITY'},
      ),
      SyntheticRetrievalQuestion(
        id: 'aster-devices',
        category: 'paraphrase',
        question: 'When must company gadgets be handed back?',
        relevantHeadings: {'EQUIPMENT RETURN'},
      ),
    ],
  ),
  SyntheticRetrievalDocument(
    id: 'synthetic-doc-02',
    title: 'Fictional Ember Workshop Safety Policy',
    text: '''
INCIDENT REPORTING

A fictional workplace accident must be reported to the Ember safety lead within twelve hours of discovery.

PROTECTIVE GEAR

Safety helmets and clear eye shields are required inside the copper fabrication bay.

EMERGENCY ASSEMBLY

After an evacuation, all workshop staff gather beside the blue clock in the east courtyard.

SAFETY TRAINING

Every workshop member renews the fictional safety course once every six months.

WEEKLY INSPECTIONS

The shift supervisor examines emergency exits and first-aid cabinets each Monday morning.
''',
    questions: [
      SyntheticRetrievalQuestion(
        id: 'ember-incident',
        category: 'deadline',
        question: 'How soon after an accident must staff notify safety?',
        relevantHeadings: {'INCIDENT REPORTING'},
      ),
      SyntheticRetrievalQuestion(
        id: 'ember-helmets',
        category: 'exact-term',
        question: 'Where are safety helmets required?',
        relevantHeadings: {'PROTECTIVE GEAR'},
      ),
      SyntheticRetrievalQuestion(
        id: 'ember-assembly',
        category: 'paraphrase',
        question: 'Where should workers meet after leaving the building?',
        relevantHeadings: {'EMERGENCY ASSEMBLY'},
      ),
      SyntheticRetrievalQuestion(
        id: 'ember-training',
        category: 'amount',
        question: 'How often is the safety course renewed?',
        relevantHeadings: {'SAFETY TRAINING'},
      ),
      SyntheticRetrievalQuestion(
        id: 'ember-inspection',
        category: 'obligation',
        question: 'Who checks the exits and first-aid cabinets?',
        relevantHeadings: {'WEEKLY INSPECTIONS'},
      ),
    ],
  ),
  SyntheticRetrievalDocument(
    id: 'synthetic-doc-03',
    title: 'Fictional Northstar Supply Contract',
    text: '''
PAYMENT TERMS

Northstar pays each undisputed fictional invoice within twenty-one days after receipt.

DELIVERY LOCATION

All fictional component crates must arrive at loading door seven of the lunar exhibit hall.

COMPONENT WARRANTY

The supplier warrants each fictional component for eighteen months after accepted delivery.

BREACH AND TERMINATION

A material breach may end the contract only if it remains uncured for ten business days after written notice.

DISPUTE PROCESS

The fictional parties must attend one remote mediation session before either party begins arbitration.
''',
    questions: [
      SyntheticRetrievalQuestion(
        id: 'northstar-payment',
        category: 'deadline',
        question: 'When is an undisputed invoice payable?',
        relevantHeadings: {'PAYMENT TERMS'},
      ),
      SyntheticRetrievalQuestion(
        id: 'northstar-delivery',
        category: 'exact-term',
        question: 'Which loading door receives component crates?',
        relevantHeadings: {'DELIVERY LOCATION'},
      ),
      SyntheticRetrievalQuestion(
        id: 'northstar-warranty',
        category: 'amount',
        question: 'How long are supplied components covered by warranty?',
        relevantHeadings: {'COMPONENT WARRANTY'},
      ),
      SyntheticRetrievalQuestion(
        id: 'northstar-breach',
        category: 'paraphrase',
        question:
            'How much time is allowed to fix a serious contract violation?',
        relevantHeadings: {'BREACH AND TERMINATION'},
      ),
      SyntheticRetrievalQuestion(
        id: 'northstar-dispute',
        category: 'obligation',
        question: 'What must happen before arbitration starts?',
        relevantHeadings: {'DISPUTE PROCESS'},
      ),
    ],
  ),
  SyntheticRetrievalDocument(
    id: 'synthetic-doc-04',
    title: 'Fictional Juniper Travel Policy',
    text: '''
HOTEL LIMIT

A fictional traveler may book lodging costing no more than 180 lunar credits per night before tax.

MEAL ALLOWANCE

The daily fictional meal allowance is 54 lunar credits and excludes entertainment purchases.

ADVANCE APPROVAL

International journeys require written approval from the Juniper travel steward before booking.

MILEAGE RATE

Use of a personal hover vehicle is reimbursed at 0.42 lunar credits per kilometer.

RECEIPT DEADLINE

Receipts for any fictional expense above 20 lunar credits must be submitted within five days after returning.
''',
    questions: [
      SyntheticRetrievalQuestion(
        id: 'juniper-hotel',
        category: 'amount',
        question: 'What is the nightly lodging cap?',
        relevantHeadings: {'HOTEL LIMIT'},
      ),
      SyntheticRetrievalQuestion(
        id: 'juniper-meals',
        category: 'exact-term',
        question: 'What is the daily meal allowance?',
        relevantHeadings: {'MEAL ALLOWANCE'},
      ),
      SyntheticRetrievalQuestion(
        id: 'juniper-approval',
        category: 'obligation',
        question: 'Who must approve an international journey before booking?',
        relevantHeadings: {'ADVANCE APPROVAL'},
      ),
      SyntheticRetrievalQuestion(
        id: 'juniper-mileage',
        category: 'paraphrase',
        question:
            'How is someone repaid for distance traveled in their own vehicle?',
        relevantHeadings: {'MILEAGE RATE'},
      ),
      SyntheticRetrievalQuestion(
        id: 'juniper-receipts',
        category: 'deadline',
        question:
            'How quickly must a large expense receipt be filed after a trip?',
        relevantHeadings: {'RECEIPT DEADLINE'},
      ),
    ],
  ),
  SyntheticRetrievalDocument(
    id: 'synthetic-doc-05',
    title: 'Fictional Cobalt Data Handling Policy',
    text: '''
RETENTION PERIOD

Fictional visitor logs are retained for 180 days and then queued for secure deletion.

SECURE DELETION

Expired fictional records are erased using the approved two-pass disposal tool.

ACCESS REVIEW

The Cobalt records custodian reviews all fictional repository permissions once per quarter.

INCIDENT ESCALATION

Suspected fictional data exposure must be escalated to the privacy captain within two hours.

PORTABLE MEDIA

Fictional records may be copied to removable storage only when the device uses approved encryption.
''',
    questions: [
      SyntheticRetrievalQuestion(
        id: 'cobalt-retention',
        category: 'amount',
        question: 'For how many days are visitor logs kept?',
        relevantHeadings: {'RETENTION PERIOD'},
      ),
      SyntheticRetrievalQuestion(
        id: 'cobalt-deletion',
        category: 'paraphrase',
        question: 'How are old records permanently removed?',
        relevantHeadings: {'SECURE DELETION'},
      ),
      SyntheticRetrievalQuestion(
        id: 'cobalt-access',
        category: 'exact-term',
        question: 'How often are repository permissions reviewed?',
        relevantHeadings: {'ACCESS REVIEW'},
      ),
      SyntheticRetrievalQuestion(
        id: 'cobalt-exposure',
        category: 'deadline',
        question: 'How soon must suspected data exposure be escalated?',
        relevantHeadings: {'INCIDENT ESCALATION'},
      ),
      SyntheticRetrievalQuestion(
        id: 'cobalt-media',
        category: 'obligation',
        question:
            'What protection is required before copying records to removable storage?',
        relevantHeadings: {'PORTABLE MEDIA'},
      ),
    ],
  ),
  SyntheticRetrievalDocument(
    id: 'synthetic-doc-06',
    title: 'Fictional Meridian Workshop Membership Agreement',
    text: '''
MEMBERSHIP TERM

Each fictional Meridian workshop membership lasts for twelve months from its activation date.

PAYMENT DUE DATE

The fictional membership fee is due on the third day of every month.

GUEST ACCESS

A member may bring one guest only while the member remains inside the workshop.

CANCELLATION NOTICE

A member must provide fourteen days of written notice to cancel a renewal.

DAMAGE DEPOSIT

The refundable fictional tool deposit is 75 lunar credits and is returned after inspection.
''',
    questions: [
      SyntheticRetrievalQuestion(
        id: 'meridian-term',
        category: 'amount',
        question: 'How long does a workshop membership last?',
        relevantHeadings: {'MEMBERSHIP TERM'},
      ),
      SyntheticRetrievalQuestion(
        id: 'meridian-payment',
        category: 'exact-term',
        question: 'On which day is the membership fee due?',
        relevantHeadings: {'PAYMENT DUE DATE'},
      ),
      SyntheticRetrievalQuestion(
        id: 'meridian-guest',
        category: 'obligation',
        question: 'What condition applies when bringing a guest?',
        relevantHeadings: {'GUEST ACCESS'},
      ),
      SyntheticRetrievalQuestion(
        id: 'meridian-cancel',
        category: 'deadline',
        question: 'How much warning is required to stop a renewal?',
        relevantHeadings: {'CANCELLATION NOTICE'},
      ),
      SyntheticRetrievalQuestion(
        id: 'meridian-deposit',
        category: 'paraphrase',
        question: 'What refundable amount is held for borrowed tools?',
        relevantHeadings: {'DAMAGE DEPOSIT'},
      ),
    ],
  ),
];
