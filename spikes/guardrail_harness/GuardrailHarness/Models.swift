import Foundation

enum SuitePurpose: String, Codable {
    case development
    case acceptance
}

enum CaseDomain: String, Codable, CaseIterable, Identifiable {
    case legal
    case medical

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Answerability: String, Codable {
    case answerable
    case unanswerable
}

struct FixtureExcerpt: Codable, Identifiable {
    let id: String
    let domain: CaseDomain
    let title: String
    let text: String
}

struct FixtureCase: Codable, Identifiable {
    let id: String
    let domain: CaseDomain
    let answerability: Answerability
    let excerptIDs: [String]
    let question: String
    let expectedAnswer: String
    let sensitiveTopics: [String]
}

struct FixtureSuite: Codable {
    let schemaVersion: Int
    let suiteID: String
    let title: String
    let fictional: Bool
    let fictionalNotice: String
    let purpose: SuitePurpose
    let promptVersion: String
    let acceptanceAttempt: Int?
    let excerpts: [FixtureExcerpt]
    let cases: [FixtureCase]

    func validate() throws {
        guard schemaVersion == 1 else {
            throw FixtureError.unsupportedSchema(schemaVersion)
        }
        guard fictional else {
            throw FixtureError.nonfictionalSuiteRejected
        }
        guard !fictionalNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FixtureError.missingFictionalNotice
        }
        guard Set(excerpts.map(\.id)).count == excerpts.count else {
            throw FixtureError.duplicateExcerptID
        }
        guard Set(cases.map(\.id)).count == cases.count else {
            throw FixtureError.duplicateCaseID
        }

        let excerptIDs = Set(excerpts.map(\.id))
        for testCase in cases {
            guard !testCase.excerptIDs.isEmpty else {
                throw FixtureError.caseHasNoExcerpt(testCase.id)
            }
            for excerptID in testCase.excerptIDs where !excerptIDs.contains(excerptID) {
                throw FixtureError.unknownExcerpt(caseID: testCase.id, excerptID: excerptID)
            }
        }

        if purpose == .acceptance {
            guard let attempt = acceptanceAttempt, (1...3).contains(attempt) else {
                throw FixtureError.invalidAcceptanceAttempt
            }
            let answerable = cases.filter { $0.answerability == .answerable }
            let unanswerable = cases.filter { $0.answerability == .unanswerable }
            guard answerable.count == 40, unanswerable.count == 10 else {
                throw FixtureError.invalidAcceptanceCounts(
                    answerable: answerable.count,
                    unanswerable: unanswerable.count
                )
            }
        }
    }

    func excerpt(for testCase: FixtureCase) throws -> String {
        let byID = Dictionary(uniqueKeysWithValues: excerpts.map { ($0.id, $0) })
        let values = try testCase.excerptIDs.map { excerptID -> String in
            guard let excerpt = byID[excerptID] else {
                throw FixtureError.unknownExcerpt(caseID: testCase.id, excerptID: excerptID)
            }
            return "\(excerpt.title)\n\n\(excerpt.text)"
        }
        return values.joined(separator: "\n\n")
    }
}

enum FixtureError: LocalizedError {
    case unsupportedSchema(Int)
    case nonfictionalSuiteRejected
    case missingFictionalNotice
    case duplicateExcerptID
    case duplicateCaseID
    case caseHasNoExcerpt(String)
    case unknownExcerpt(caseID: String, excerptID: String)
    case invalidAcceptanceAttempt
    case invalidAcceptanceCounts(answerable: Int, unanswerable: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported fixture schema version: \(version)."
        case .nonfictionalSuiteRejected:
            return "The harness accepts committed suites only when fictional is true."
        case .missingFictionalNotice:
            return "The suite must contain an explicit fictional-data notice."
        case .duplicateExcerptID:
            return "The suite contains duplicate excerpt IDs."
        case .duplicateCaseID:
            return "The suite contains duplicate case IDs."
        case .caseHasNoExcerpt(let caseID):
            return "Case \(caseID) does not reference an excerpt."
        case .unknownExcerpt(let caseID, let excerptID):
            return "Case \(caseID) references unknown excerpt \(excerptID)."
        case .invalidAcceptanceAttempt:
            return "An acceptance suite must declare an attempt from 1 through 3."
        case .invalidAcceptanceCounts(let answerable, let unanswerable):
            return "Acceptance suites require 40 answerable and 10 unanswerable cases; found \(answerable) and \(unanswerable)."
        }
    }
}

enum AutomaticOutcome: String, Codable, Sendable {
    case generated
    case thrownGuardrail
    case modelUnavailable
    case runtimeFailure
}

enum ManualGrade: String, Codable, CaseIterable, Identifiable {
    case correct
    case incorrect
    case hardGuardrailRefusal
    case verbalRefusal
    case properAbstention
    case hallucination
    case runtimeFailure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .correct: return "Correct"
        case .incorrect: return "Incorrect"
        case .hardGuardrailRefusal: return "Hard guardrail refusal"
        case .verbalRefusal: return "Verbal refusal"
        case .properAbstention: return "Proper abstention"
        case .hallucination: return "Invented answer"
        case .runtimeFailure: return "Runtime failure"
        }
    }

    var requiresRerun: Bool {
        switch self {
        case .correct, .properAbstention:
            return false
        case .incorrect, .hardGuardrailRefusal, .verbalRefusal, .hallucination, .runtimeFailure:
            return true
        }
    }

    var isPassing: Bool {
        self == .correct || self == .properAbstention
    }
}

struct ModelRun: Sendable {
    let output: String
    let latencyMilliseconds: Int
    let automaticOutcome: AutomaticOutcome
    let errorDescription: String?
}

struct CaseResult: Codable, Identifiable {
    let id: UUID
    let caseID: String
    let domain: CaseDomain
    let answerability: Answerability
    let runNumber: Int
    let output: String
    let latencyMilliseconds: Int
    let automaticOutcome: AutomaticOutcome
    let errorDescription: String?
    let manualGrade: ManualGrade
    let sensitiveTopics: [String]
}

struct ResultEnvelope: Codable {
    let schemaVersion: Int
    let suiteID: String
    let suitePurpose: SuitePurpose
    let promptVersion: String
    let acceptanceAttempt: Int?
    let operatingSystem: String
    let deviceModel: String
    let exportedAt: Date
    let systematicRefusalObserved: Bool
    let rerunCaseIDs: [String]
    let results: [CaseResult]
}

struct GateMetrics {
    let answerableCount: Int
    let correctCount: Int
    let benignRefusalCount: Int
    let unanswerableCount: Int
    let properAbstentionCount: Int
    let inventedAnswerCount: Int
    let medianLatencyMilliseconds: Int?
    let passesNumericalThresholds: Bool
}

struct QueuedCase: Identifiable {
    let testCase: FixtureCase
    let runNumber: Int

    var id: String { "\(testCase.id)-run-\(runNumber)" }
}
