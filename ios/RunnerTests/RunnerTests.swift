import Foundation
import FoundationModels
import NaturalLanguage
import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {
  func testAvailabilityReportsLanguageDimensionAndRevision() {
    let service = AppleSentenceEmbeddingService(
      model: FakeSentenceEmbeddingModel(
        dimension: 3,
        revision: 7,
        vector: [0.25, -0.5, 1]
      )
    )

    let availability = service.availability()

    XCTAssertEqual(availability["available"] as? Bool, true)
    XCTAssertEqual(availability["language"] as? String, "en")
    XCTAssertEqual(availability["dimensions"] as? Int, 3)
    XCTAssertEqual(availability["revision"] as? Int, 7)
  }

  func testUnavailableModelIsReportedExplicitly() {
    let availability = AppleSentenceEmbeddingService(model: nil).availability()

    XCTAssertEqual(availability["available"] as? Bool, false)
    XCTAssertEqual(availability["language"] as? String, "en")
    XCTAssertNotNil(availability["reason"] as? String)
  }

  func testEmbeddingOutputMatchesTheRuntimeShape() throws {
    let service = AppleSentenceEmbeddingService(
      model: FakeSentenceEmbeddingModel(
        dimension: 3,
        revision: 1,
        vector: [0.25, -0.5, 1]
      )
    )

    XCTAssertEqual(try service.embed("A fictional sentence."), [0.25, -0.5, 1])
  }

  func testEmbeddingErrorsHaveStableBridgeCodes() {
    let unavailable = AppleSentenceEmbeddingService(model: nil)
    XCTAssertThrowsError(try unavailable.embed("A sentence.")) { error in
      XCTAssertEqual(
        error as? AppleSentenceEmbeddingError,
        .embeddingUnavailable
      )
      XCTAssertEqual(
        (error as? AppleSentenceEmbeddingError)?.rawValue,
        "embedding_unavailable"
      )
    }

    let empty = AppleSentenceEmbeddingService(
      model: FakeSentenceEmbeddingModel(
        dimension: 1,
        revision: 1,
        vector: [1]
      )
    )
    XCTAssertThrowsError(try empty.embed("   \n")) { error in
      XCTAssertEqual(error as? AppleSentenceEmbeddingError, .invalidInput)
    }

    let missingVector = AppleSentenceEmbeddingService(
      model: FakeSentenceEmbeddingModel(
        dimension: 1,
        revision: 1,
        vector: nil
      )
    )
    XCTAssertThrowsError(try missingVector.embed("A sentence.")) { error in
      XCTAssertEqual(error as? AppleSentenceEmbeddingError, .vectorUnavailable)
    }

    let wrongShape = AppleSentenceEmbeddingService(
      model: FakeSentenceEmbeddingModel(
        dimension: 2,
        revision: 1,
        vector: [1]
      )
    )
    XCTAssertThrowsError(try wrongShape.embed("A sentence.")) { error in
      XCTAssertEqual(error as? AppleSentenceEmbeddingError, .dimensionMismatch)
    }
  }

  @available(iOS 14.0, *)
  func testAppleEmbeddingFindsTheFictionalSemanticMatch() throws {
    guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
      throw XCTSkip("English sentence embeddings are unavailable on this test device.")
    }
    guard
      let question = model.vector(
        for: "How soon should employees disclose a workplace accident?"
      ),
      let relevant = model.vector(
        for: "Aster Workshop staff must notify the safety officer within a fortnight."
      ),
      let unrelated = model.vector(
        for: "The cafeteria walls are painted blue and the chairs are wooden."
      )
    else {
      XCTFail("Apple returned no sentence vector for the fictional fixture.")
      return
    }

    XCTAssertGreaterThan(
      cosineSimilarity(question, relevant),
      cosineSimilarity(question, unrelated)
    )
  }

  func testFoundationModelAvailabilityMappingIsStable() {
    for status in [
      FoundationModelAvailabilityStatus.available,
      .deviceNotEligible,
      .appleIntelligenceNotEnabled,
      .modelNotReady,
    ] {
      let service = AppleFoundationModelService(
        runtime: FakeFoundationModelRuntime(status: status)
      )

      XCTAssertEqual(
        service.availabilityPayload()["status"] as? String,
        status.rawValue
      )
    }
  }

  func testFoundationModelContextAndTokenCountingUseTheRuntime() async throws {
    let runtime = FakeFoundationModelRuntime(
      status: .available,
      contextSize: 4_096,
      tokenCount: 37
    )
    let service = AppleFoundationModelService(runtime: runtime)

    XCTAssertEqual(try service.contextSize(), 4_096)
    let instructionCount = try await service.countTokens(
      "Instructions",
      kind: .instructions
    )
    let promptCount = try await service.countTokens("Prompt", kind: .prompt)
    XCTAssertEqual(instructionCount, 37)
    XCTAssertEqual(promptCount, 37)
    XCTAssertEqual(runtime.countedKinds, [.instructions, .prompt])
  }

  func testFoundationModelStreamsFictionalPlainStringAnswer() async throws {
    let runtime = FakeFoundationModelRuntime(
      status: .available,
      snapshots: [
        "The fictional",
        "The fictional incident deadline is fourteen days.",
      ]
    )
    let service = AppleFoundationModelService(runtime: runtime)
    let stream = try service.responseStream(
      prompt: "<document_excerpt>Fictional policy.</document_excerpt>"
    )
    var snapshots: [String] = []

    for try await snapshot in stream {
      snapshots.append(snapshot)
    }

    XCTAssertEqual(
      snapshots,
      [
        "The fictional",
        "The fictional incident deadline is fourteen days.",
      ]
    )
  }

  @available(iOS 26.0, *)
  func testFoundationModelGenerationErrorsHaveStableBridgeCodes() {
    let context = LanguageModelSession.GenerationError.Context(
      debugDescription: "PRIVATE NATIVE DETAIL"
    )

    XCTAssertEqual(
      SystemFoundationModelRuntime.map(
        LanguageModelSession.GenerationError.exceededContextWindowSize(context)
      ).rawValue,
      FoundationModelBridgeFailure.contextOverflow.rawValue
    )
    XCTAssertEqual(
      SystemFoundationModelRuntime.map(
        LanguageModelSession.GenerationError.guardrailViolation(context)
      ).rawValue,
      FoundationModelBridgeFailure.guardrailViolation.rawValue
    )
    XCTAssertEqual(
      SystemFoundationModelRuntime.map(
        LanguageModelSession.GenerationError.decodingFailure(context)
      ).rawValue,
      FoundationModelBridgeFailure.streamFailure.rawValue
    )
  }

  @available(iOS 26.0, *)
  func testGuardrailV1ProductionPromptRemainsFrozen() {
    XCTAssertEqual(SystemFoundationModelRuntime.promptVersion, "guardrail-v1")
    XCTAssertTrue(
      SystemFoundationModelRuntime.instructions.contains(
        "only the supplied document excerpt"
      )
    )
    XCTAssertTrue(
      SystemFoundationModelRuntime.instructions.contains(
        "I couldn’t find enough evidence in this document."
      )
    )
  }

  func testDatabaseReceivesCompleteFileProtection() throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("iOS file-protection attributes require a physical device.")
    #else
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("library.sqlite3")
    FileManager.default.createFile(atPath: database.path, contents: Data())

    try AppleFileProtectionService.protect(
      directoryPath: directory.path,
      databasePath: database.path
    )

    let attributes = try FileManager.default.attributesOfItem(
      atPath: database.path
    )
    XCTAssertEqual(
      attributes[.protectionKey] as? FileProtectionType,
      FileProtectionType.complete
    )
    #endif
  }
}

private final class FakeFoundationModelRuntime: FoundationModelRuntime {
  init(
    status: FoundationModelAvailabilityStatus,
    contextSize: Int = 4_096,
    tokenCount: Int = 1,
    snapshots: [String] = [],
    failure: FoundationModelBridgeFailure? = nil
  ) {
    self.status = status
    self.reportedContextSize = contextSize
    self.reportedTokenCount = tokenCount
    self.snapshots = snapshots
    self.failure = failure
  }

  let status: FoundationModelAvailabilityStatus
  let reportedContextSize: Int
  let reportedTokenCount: Int
  let snapshots: [String]
  let failure: FoundationModelBridgeFailure?
  private(set) var countedKinds: [FoundationModelTokenKind] = []

  func availability() -> FoundationModelAvailabilityStatus { status }

  func contextSize() throws -> Int { reportedContextSize }

  func countTokens(
    _ text: String,
    kind: FoundationModelTokenKind
  ) async throws -> Int {
    countedKinds.append(kind)
    if let failure { throw failure }
    return reportedTokenCount
  }

  func responseStream(prompt: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      if let failure {
        continuation.finish(throwing: failure)
        return
      }
      for snapshot in snapshots {
        continuation.yield(snapshot)
      }
      continuation.finish()
    }
  }
}

private final class FakeSentenceEmbeddingModel: SentenceEmbeddingModel {
  init(dimension: Int, revision: Int, vector: [Double]?) {
    self.dimension = dimension
    self.revision = revision
    self.vector = vector
  }

  let dimension: Int
  let revision: Int
  let vector: [Double]?

  func vector(for string: String) -> [Double]? {
    vector
  }
}

private func cosineSimilarity(_ left: [Double], _ right: [Double]) -> Double {
  guard left.count == right.count, !left.isEmpty else { return 0 }
  var dotProduct = 0.0
  var leftMagnitude = 0.0
  var rightMagnitude = 0.0
  for index in left.indices {
    dotProduct += left[index] * right[index]
    leftMagnitude += left[index] * left[index]
    rightMagnitude += right[index] * right[index]
  }
  guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
  return dotProduct / sqrt(leftMagnitude * rightMagnitude)
}
