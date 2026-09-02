import XCTest
@testable import ConnorPet

final class UsageLabelTests: XCTestCase {
    func testFormatTokensCompact() {
        XCTAssertEqual(XPModel.formatTokens(0), "0")
        XCTAssertEqual(XPModel.formatTokens(950), "950")
        XCTAssertEqual(XPModel.formatTokens(800_000), "800k")
        XCTAssertEqual(XPModel.formatTokens(200_000), "200k")
        XCTAssertEqual(XPModel.formatTokens(6_500_000), "6.5M")
        XCTAssertEqual(XPModel.formatTokens(33_640_000), "33.6M")
        XCTAssertEqual(XPModel.formatTokens(100_000_000), "100M")
        XCTAssertEqual(XPModel.formatTokens(850_000_000), "850M")
        XCTAssertEqual(XPModel.formatTokens(1_000_000_000), "1B")
    }

    // Label format: "<cumulative> / <max> (<pct>%)". Percent shows one decimal
    // below 10% (so a tiny weekly fraction is legible) and an integer above.
    func testUsageLabel() {
        XCTAssertEqual(XPModel.usageLabel(cumulative: 800_000, max: 100_000_000), "800k / 100M (0.8%)")
        XCTAssertEqual(XPModel.usageLabel(cumulative: 850_000_000, max: 100_000_000), "850M / 100M (850%)")
        XCTAssertEqual(XPModel.usageLabel(cumulative: 20_000_000, max: 100_000_000), "20M / 100M (20%)")
    }

    func testUsageLabelZeroMaxIsSafe() {
        XCTAssertEqual(XPModel.usageLabel(cumulative: 5_000_000, max: 0), "5M / 0 (0%)")
    }

    // Weekly cumulative sums EVERYTHING including cache_read (the user's choice),
    // across every assistant message in the transcript.
    func testWeeklySumIncludesCacheRead() {
        let jsonl = """
        {"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":25}}}
        """
        // (10+1000+100+50) + (5+2000+0+25) = 1160 + 2030 = 3190
        XCTAssertEqual(WeeklyUsageReader.sumAllTokens(in: Data(jsonl.utf8)), 3190, accuracy: 0.5)
    }
}
