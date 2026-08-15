import XCTest
@testable import GuardrailHarness

final class ModelsTests: XCTestCase {
    func testRejectsMismatchedCaseAndExcerptDomains() throws {
        let suite = try modifiedSuite { root in
            var cases = root["cases"] as! [[String: Any]]
            let current = cases[0]["domain"] as! String
            cases[0]["domain"] = current == "legal" ? "medical" : "legal"
            root["cases"] = cases
        }

        XCTAssertThrowsError(try suite.validate())
    }

    func testRejectsExcerptOutsideWordLimit() throws {
        let suite = try modifiedSuite { root in
            var excerpts = root["excerpts"] as! [[String: Any]]
            excerpts[0]["text"] = "Too short for the acceptance harness."
            root["excerpts"] = excerpts
        }

        XCTAssertThrowsError(try suite.validate())
    }

    func testRejectsMissingSensitiveTopicLabels() throws {
        let suite = try modifiedSuite { root in
            var cases = root["cases"] as! [[String: Any]]
            cases[0]["sensitiveTopics"] = [String]()
            root["cases"] = cases
        }

        XCTAssertThrowsError(try suite.validate())
    }

    func testRejectsIncorrectDomainDistribution() throws {
        let suite = try modifiedSuite { root in
            var cases = root["cases"] as! [[String: Any]]
            cases.removeLast()
            root["cases"] = cases
        }

        XCTAssertThrowsError(try suite.validate())
    }

    func testMedianAveragesTheTwoMiddleLatencies() {
        XCTAssertEqual(medianLatencyMilliseconds([10, 20, 30, 40]), 25)
    }

    private func modifiedSuite(
        _ change: (inout [String: Any]) -> Void
    ) throws -> FixtureSuite {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "development_suite",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: url)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        change(&root)
        let changedData = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(FixtureSuite.self, from: changedData)
    }
}
