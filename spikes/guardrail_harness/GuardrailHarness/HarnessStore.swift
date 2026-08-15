import Foundation
import UIKit
import Combine

@MainActor
final class HarnessStore: ObservableObject {
    @Published private(set) var suite: FixtureSuite?
    @Published private(set) var queue: [QueuedCase] = []
    @Published private(set) var queueIndex = 0
    @Published private(set) var results: [CaseResult] = []
    @Published private(set) var currentRun: ModelRun?
    @Published private(set) var isRunning = false
    @Published private(set) var isRerun = false
    @Published private(set) var rerunCaseIDs: [String] = []
    @Published var selectedGrade: ManualGrade = .correct
    @Published var systematicRefusalObserved = false
    @Published private(set) var statusMessage = "Loading fictional development suite…"
    @Published private(set) var modelAvailability = "Checking…"

    @Published var privateDomain: CaseDomain = .legal
    @Published var privateExcerpt = ""
    @Published var privateQuestion = ""
    @Published private(set) var privateRun: ModelRun?
    @Published var privateGrade: ManualGrade = .correct
    @Published private(set) var privateSummaries: [PrivateRunSummary] = []

    private let runner = FoundationModelRunner()
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init() {
        loadBundledDevelopmentSuite()
        Task {
            modelAvailability = await runner.availabilityDescription()
        }
    }

    var currentQueuedCase: QueuedCase? {
        guard queue.indices.contains(queueIndex) else { return nil }
        return queue[queueIndex]
    }

    var currentExcerpt: String {
        guard let suite, let queued = currentQueuedCase else { return "" }
        return (try? suite.excerpt(for: queued.testCase)) ?? "Fixture excerpt could not be resolved."
    }

    var hasCompletedCurrentQueue: Bool {
        !queue.isEmpty && queueIndex >= queue.count
    }

    var canPrepareRerun: Bool {
        hasCompletedCurrentQueue && !isRerun && !results.isEmpty
    }

    var canExport: Bool {
        guard let suite else { return false }
        return suite.fictional && !results.isEmpty
    }

    var gateMetrics: GateMetrics {
        let initial = results.filter { $0.runNumber == 1 }
        let answerable = initial.filter { $0.answerability == .answerable }
        let unanswerable = initial.filter { $0.answerability == .unanswerable }
        let correct = answerable.filter { $0.manualGrade == .correct }.count
        let refusals = answerable.filter {
            $0.manualGrade == .hardGuardrailRefusal || $0.manualGrade == .verbalRefusal
        }.count
        let abstentions = unanswerable.filter { $0.manualGrade == .properAbstention }.count
        let invented = unanswerable.filter { $0.manualGrade == .hallucination }.count
        let median = medianLatencyMilliseconds(
            initial.map(\.latencyMilliseconds)
        )

        return GateMetrics(
            answerableCount: answerable.count,
            correctCount: correct,
            benignRefusalCount: refusals,
            unanswerableCount: unanswerable.count,
            properAbstentionCount: abstentions,
            inventedAnswerCount: invented,
            medianLatencyMilliseconds: median,
            passesNumericalThresholds: answerable.count == 40
                && correct >= 32
                && refusals <= 2
                && unanswerable.count == 10
                && abstentions >= 9
                && !systematicRefusalObserved
        )
    }

    func loadSuite(data: Data) {
        do {
            let decoded = try decoder.decode(FixtureSuite.self, from: data)
            try decoded.validate()
            guard decoded.promptVersion == GatePrompt.version else {
                throw HarnessError.promptVersionMismatch(
                    suite: decoded.promptVersion,
                    app: GatePrompt.version
                )
            }
            suite = decoded
            queue = decoded.cases.map { QueuedCase(testCase: $0, runNumber: 1) }
            queueIndex = 0
            results = []
            currentRun = nil
            isRerun = false
            rerunCaseIDs = []
            systematicRefusalObserved = false
            statusMessage = "Loaded \(decoded.title). All content is fictional."
        } catch {
            statusMessage = "Suite rejected: \(error.localizedDescription)"
        }
    }

    func runCurrentCase() async {
        guard let queued = currentQueuedCase, !isRunning else { return }
        isRunning = true
        currentRun = nil
        selectedGrade = queued.testCase.answerability == .answerable ? .correct : .properAbstention
        let run = await runner.run(
            excerpt: currentExcerpt,
            question: queued.testCase.question
        )
        currentRun = run
        if run.automaticOutcome == .thrownGuardrail {
            selectedGrade = .hardGuardrailRefusal
        } else if run.automaticOutcome != .generated {
            selectedGrade = .runtimeFailure
        }
        isRunning = false
    }

    func submitCurrentGrade() {
        guard let queued = currentQueuedCase, let currentRun else { return }
        let result = CaseResult(
            id: UUID(),
            caseID: queued.testCase.id,
            domain: queued.testCase.domain,
            answerability: queued.testCase.answerability,
            runNumber: queued.runNumber,
            output: currentRun.output,
            latencyMilliseconds: currentRun.latencyMilliseconds,
            automaticOutcome: currentRun.automaticOutcome,
            errorDescription: currentRun.errorDescription,
            manualGrade: selectedGrade,
            sensitiveTopics: queued.testCase.sensitiveTopics
        )
        results.append(result)
        queueIndex += 1
        self.currentRun = nil
    }

    func prepareReruns() {
        guard let suite, canPrepareRerun else { return }
        let initial = results.filter { $0.runNumber == 1 }
        let required = initial.filter { $0.manualGrade.requiresRerun }
        let sampledPassing = Array(initial.filter { $0.manualGrade.isPassing }.shuffled().prefix(10))
        let selectedIDs = Array(Set((required + sampledPassing).map(\.caseID))).sorted()
        let byID = Dictionary(uniqueKeysWithValues: suite.cases.map { ($0.id, $0) })
        queue = selectedIDs.compactMap { byID[$0] }.map { QueuedCase(testCase: $0, runNumber: 2) }
        rerunCaseIDs = selectedIDs
        queueIndex = 0
        currentRun = nil
        isRerun = true
        statusMessage = "Prepared \(queue.count) reruns: all failures plus up to ten sampled passes."
    }

    func exportResults() throws -> Data {
        guard let suite else { throw HarnessError.noSuiteLoaded }
        guard suite.fictional else { throw HarnessError.privateExportForbidden }
        let envelope = ResultEnvelope(
            schemaVersion: 1,
            suiteID: suite.suiteID,
            suitePurpose: suite.purpose,
            promptVersion: suite.promptVersion,
            acceptanceAttempt: suite.acceptanceAttempt,
            operatingSystem: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            exportedAt: Date(),
            systematicRefusalObserved: systematicRefusalObserved,
            rerunCaseIDs: rerunCaseIDs,
            results: results
        )
        return try encoder.encode(envelope)
    }

    func runPrivateCase() async {
        guard !privateExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !privateQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isRunning else { return }
        isRunning = true
        privateRun = nil
        privateGrade = .correct
        let run = await runner.run(excerpt: privateExcerpt, question: privateQuestion)
        privateRun = run
        if run.automaticOutcome == .thrownGuardrail {
            privateGrade = .hardGuardrailRefusal
        } else if run.automaticOutcome != .generated {
            privateGrade = .runtimeFailure
        }
        isRunning = false
    }

    func submitPrivateGrade() {
        guard let privateRun else { return }
        privateSummaries.append(
            PrivateRunSummary(
                domain: privateDomain,
                grade: privateGrade,
                latencyMilliseconds: privateRun.latencyMilliseconds,
                automaticOutcome: privateRun.automaticOutcome
            )
        )
        privateExcerpt = ""
        privateQuestion = ""
        self.privateRun = nil
    }

    func clearPrivateSession() {
        privateExcerpt = ""
        privateQuestion = ""
        privateRun = nil
        privateSummaries = []
        privateGrade = .correct
    }

    private func loadBundledDevelopmentSuite() {
        guard let url = Bundle.main.url(
            forResource: "development_suite",
            withExtension: "json"
        ) else {
            statusMessage = "Bundled development_suite.json is missing."
            return
        }
        do {
            loadSuite(data: try Data(contentsOf: url))
        } catch {
            statusMessage = "Could not read bundled suite: \(error.localizedDescription)"
        }
    }
}

struct PrivateRunSummary: Identifiable {
    let id = UUID()
    let domain: CaseDomain
    let grade: ManualGrade
    let latencyMilliseconds: Int
    let automaticOutcome: AutomaticOutcome
}

enum HarnessError: LocalizedError {
    case noSuiteLoaded
    case privateExportForbidden
    case promptVersionMismatch(suite: String, app: String)

    var errorDescription: String? {
        switch self {
        case .noSuiteLoaded:
            return "No suite is loaded."
        case .privateExportForbidden:
            return "Private results cannot be exported."
        case .promptVersionMismatch(let suite, let app):
            return "Suite prompt version \(suite) does not match app prompt version \(app)."
        }
    }
}
