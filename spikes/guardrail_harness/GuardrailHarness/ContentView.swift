import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            SyntheticSuiteView()
                .tabItem { Label("Synthetic", systemImage: "checklist") }

            PrivateSmokeTestView()
                .tabItem { Label("Private", systemImage: "lock.shield") }

            HarnessAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

private struct SyntheticSuiteView: View {
    @EnvironmentObject private var store: HarnessStore
    @State private var importingSuite = false
    @State private var exportingResults = false
    @State private var resultDocument: ResultDocument?
    @State private var presentedError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fictionalBanner
                    modelStatus

                    if let suite = store.suite {
                        suiteHeader(suite)
                    }

                    if let queued = store.currentQueuedCase {
                        caseCard(queued)
                    } else if store.hasCompletedCurrentQueue {
                        summaryCard
                    }
                }
                .padding()
            }
            .navigationTitle("Guardrail Gate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import suite") { importingSuite = true }
                }
            }
            .fileImporter(
                isPresented: $importingSuite,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                importSuite(result)
            }
            .fileExporter(
                isPresented: $exportingResults,
                document: resultDocument,
                contentType: .json,
                defaultFilename: defaultExportFilename
            ) { result in
                if case .failure(let error) = result {
                    presentedError = error.localizedDescription
                }
            }
            .alert(
                "Harness error",
                isPresented: Binding(
                    get: { presentedError != nil },
                    set: { if !$0 { presentedError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { presentedError = nil }
            } message: {
                Text(presentedError ?? "Unknown error")
            }
        }
    }

    private var fictionalBanner: some View {
        Label(
            "FICTIONAL TEST DATA — not a real contract, medical record, or professional advice.",
            systemImage: "theatermasks.fill"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.purple)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var modelStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model: \(store.modelAvailability)")
                .font(.subheadline.weight(.medium))
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func suiteHeader(_ suite: FixtureSuite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suite.title).font(.title3.weight(.semibold))
            Text("\(suite.purpose.rawValue.capitalized) · prompt \(suite.promptVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(
                value: Double(min(store.queueIndex, store.queue.count)),
                total: Double(max(store.queue.count, 1))
            )
            Text("\(min(store.queueIndex, store.queue.count)) of \(store.queue.count) graded\(store.isRerun ? " in rerun" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func caseCard(_ queued: QueuedCase) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(queued.testCase.id).font(.headline)
                Spacer()
                Text("Run \(queued.runNumber)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            labeledText("Question", queued.testCase.question)
            labeledText("Expected", queued.testCase.expectedAnswer)

            DisclosureGroup("Relevant fictional excerpt") {
                Text(store.currentExcerpt)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }

            if let run = store.currentRun {
                Divider()
                labeledText(
                    "Model output",
                    run.output.isEmpty ? "No text returned." : run.output
                )
                Text("Automatic outcome: \(run.automaticOutcome.rawValue) · \(run.latencyMilliseconds) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = run.errorDescription {
                    labeledText("Error", error)
                }

                Picker("Manual grade", selection: $store.selectedGrade) {
                    ForEach(ManualGrade.allCases) { grade in
                        Text(grade.title).tag(grade)
                    }
                }
                .pickerStyle(.menu)

                Button("Save grade and continue") {
                    store.submitCurrentGrade()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await store.runCurrentCase() }
                } label: {
                    if store.isRunning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Run case").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRunning || store.modelAvailability != "Available")
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var summaryCard: some View {
        let metrics = store.gateMetrics
        return VStack(alignment: .leading, spacing: 12) {
            Text(store.isRerun ? "Reruns complete" : "Initial run complete")
                .font(.title3.weight(.semibold))
            metric("Answerable correct", "\(metrics.correctCount)/\(metrics.answerableCount)")
            metric("Benign refusals", "\(metrics.benignRefusalCount)")
            metric("Proper abstentions", "\(metrics.properAbstentionCount)/\(metrics.unanswerableCount)")
            metric("Invented unanswerable answers", "\(metrics.inventedAnswerCount)")
            metric(
                "Median latency",
                metrics.medianLatencyMilliseconds.map { "\($0) ms" } ?? "Not available"
            )

            Toggle(
                "A systematic refusal category was observed",
                isOn: $store.systematicRefusalObserved
            )

            Label(
                metrics.passesNumericalThresholds
                    ? "Numerical thresholds pass"
                    : "Numerical thresholds do not pass",
                systemImage: metrics.passesNumericalThresholds
                    ? "checkmark.seal.fill"
                    : "xmark.octagon.fill"
            )
            .foregroundStyle(metrics.passesNumericalThresholds ? .green : .red)

            if store.canPrepareRerun {
                Button("Prepare required reruns") {
                    store.prepareReruns()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Export fictional results") {
                do {
                    resultDocument = ResultDocument(data: try store.exportResults())
                    exportingResults = true
                } catch {
                    presentedError = error.localizedDescription
                }
            }
            .buttonStyle(.bordered)
            .disabled(!store.canExport)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func labeledText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
    }

    private var defaultExportFilename: String {
        "\(store.suite?.suiteID ?? "guardrail")-results"
    }

    private func importSuite(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            store.loadSuite(data: try Data(contentsOf: url))
        } catch {
            presentedError = error.localizedDescription
        }
    }
}

private struct PrivateSmokeTestView: View {
    @EnvironmentObject private var store: HarnessStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(
                        "PRIVATE MODE — nothing here is saved or exportable. Backgrounding clears the entire session.",
                        systemImage: "lock.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding()
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                    Text("Model: \(store.modelAvailability)")
                        .font(.subheadline)

                    Picker("Document type", selection: $store.privateDomain) {
                        ForEach(CaseDomain.allCases) { domain in
                            Text(domain.title).tag(domain)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Excerpt").font(.headline)
                    TextEditor(text: $store.privateExcerpt)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .autocorrectionDisabled(true)

                    Text("Question").font(.headline)
                    TextEditor(text: $store.privateQuestion)
                        .frame(minHeight: 90)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .autocorrectionDisabled(true)

                    if let run = store.privateRun {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model output").font(.headline)
                            Text(run.output.isEmpty ? "No text returned." : run.output)
                                .textSelection(.enabled)
                            Text("\(run.automaticOutcome.rawValue) · \(run.latencyMilliseconds) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = run.errorDescription {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }

                        Picker("Your grade", selection: $store.privateGrade) {
                            ForEach(ManualGrade.allCases) { grade in
                                Text(grade.title).tag(grade)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Record aggregate and clear case") {
                            store.submitPrivateGrade()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await store.runPrivateCase() }
                        } label: {
                            if store.isRunning {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Run private case").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            store.isRunning
                                || store.modelAvailability != "Available"
                                || store.privateExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || store.privateQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }

                    privateSummary

                    Button("End and erase private session", role: .destructive) {
                        store.clearPrivateSession()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Private Smoke Test")
        }
    }

    private var privateSummary: some View {
        let summaries = store.privateSummaries
        let correct = summaries.filter { $0.grade == .correct }.count
        let refusals = summaries.filter {
            $0.grade == .hardGuardrailRefusal || $0.grade == .verbalRefusal
        }.count
        let invented = summaries.filter { $0.grade == .hallucination }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Session-only aggregate").font(.headline)
            Text("Cases: \(summaries.count)/10 · correct: \(correct) · refusals: \(refusals) · invented: \(invented)")
                .font(.subheadline)
            if summaries.count == 10 {
                Label(
                    refusals == 0 && correct >= 8 && invented == 0
                        ? "Private gate passes"
                        : "Private gate does not pass",
                    systemImage: refusals == 0 && correct >= 8 && invented == 0
                        ? "checkmark.seal.fill"
                        : "xmark.octagon.fill"
                )
                .foregroundStyle(refusals == 0 && correct >= 8 && invented == 0 ? .green : .red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HarnessAboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Purpose") {
                    Text("This disposable app measures Foundation Models guardrail behavior before Sekret Midget’s Flutter application is created.")
                }
                Section("Authoritative run") {
                    Text("Install a Release build on the iPhone 15 Pro Max, confirm Apple Intelligence is ready, disconnect the Mac, enable airplane mode, and run the suite.")
                }
                Section("Prompt") {
                    Text("Version: \(GatePrompt.version)")
                    Text("Plain-string output with permissive content transformations. Citations are intentionally outside this spike.")
                }
                Section("Privacy") {
                    Text("No network or analytics code is present. Synthetic results may be exported. Private excerpts, questions, and outputs cannot be exported and are cleared on backgrounding.")
                }
            }
            .navigationTitle("About the Harness")
        }
    }
}
