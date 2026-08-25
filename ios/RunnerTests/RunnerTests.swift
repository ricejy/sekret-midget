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
