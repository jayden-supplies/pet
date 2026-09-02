import XCTest
@testable import ConnorPet

final class XPModelTests: XCTestCase {
    private let acc = 0.0001

    // MARK: - percent: XP% is the agent's context-window usage (matches Orca's
    // "N% 사용" indicator), i.e. current context tokens / 1,000,000.

    func testPercentIsContextOverOneMillion() {
        XCTAssertEqual(XPModel.percent(contextTokens: 80_000), 0.08, accuracy: acc)
        XCTAssertEqual(XPModel.percent(contextTokens: 300_000), 0.30, accuracy: acc)
        XCTAssertEqual(XPModel.percent(contextTokens: 0), 0.0, accuracy: acc)
    }

    func testPercentClampsToOne() {
        XCTAssertEqual(XPModel.percent(contextTokens: 2_000_000), 1.0, accuracy: acc)
    }

    // MARK: - stage: number of thresholds reached.

    func testStage() {
        let t = [0.30, 0.60]
        XCTAssertEqual(XPModel.stage(percent: 0.08, thresholds: t), 0)
        XCTAssertEqual(XPModel.stage(percent: 0.30, thresholds: t), 1) // inclusive
        XCTAssertEqual(XPModel.stage(percent: 0.45, thresholds: t), 1)
        XCTAssertEqual(XPModel.stage(percent: 0.60, thresholds: t), 2)
        XCTAssertEqual(XPModel.stage(percent: 0.99, thresholds: t), 2)
    }

    // MARK: - barFill: progress WITHIN the current stage toward the next
    // threshold, not absolute percent. This is the core of the user's request:
    // "at 8% with a 30% stage-1 condition, the bar should be 8/30 ≈ 26.7% full".

    func testBarFillTowardNextThreshold_theEightOverThirtyExample() {
        XCTAssertEqual(XPModel.barFill(percent: 0.08, thresholds: [0.30, 0.60]),
                       0.08 / 0.30, accuracy: acc) // ≈ 0.2667
    }

    func testBarFillAtStageStartIsZero() {
        // Exactly at a threshold: just entered the next stage, fill resets to 0.
        XCTAssertEqual(XPModel.barFill(percent: 0.30, thresholds: [0.30, 0.60]), 0.0, accuracy: acc)
    }

    func testBarFillMidStageOne() {
        // Halfway between stage-1 (0.30) and stage-2 (0.60).
        XCTAssertEqual(XPModel.barFill(percent: 0.45, thresholds: [0.30, 0.60]), 0.5, accuracy: acc)
    }

    func testBarFillAtAndAboveFinalStageIsFull() {
        XCTAssertEqual(XPModel.barFill(percent: 0.60, thresholds: [0.30, 0.60]), 1.0, accuracy: acc)
        XCTAssertEqual(XPModel.barFill(percent: 0.95, thresholds: [0.30, 0.60]), 1.0, accuracy: acc)
    }

    func testBarFillZeroPercent() {
        XCTAssertEqual(XPModel.barFill(percent: 0.0, thresholds: [0.30, 0.60]), 0.0, accuracy: acc)
    }
}

final class TranscriptTokenReaderTests: XCTestCase {
    // Context usage tracks the LATEST turn's prompt size (input + cache_read +
    // cache_creation), matching what the agent tools show "right now" — not a
    // sum across the whole session.
    func testLatestContextTokensUsesLastMessageWithUsage() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":10000,"cache_creation_input_tokens":2000,"output_tokens":100}}}
        {"type":"assistant","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":50000,"cache_creation_input_tokens":1000,"output_tokens":200}}}
        {"type":"user","message":{"role":"user","content":"no usage here"}}
        """
        let data = Data(jsonl.utf8)
        // last message context = 3 + 50000 + 1000 = 51003 (NOT the earlier 12005, NOT a sum)
        XCTAssertEqual(TranscriptTokenReader.latestContextTokens(in: data), 51003, accuracy: 0.5)
    }

    func testLatestContextTokensEmpty() {
        XCTAssertEqual(TranscriptTokenReader.latestContextTokens(in: Data("{}\n".utf8)), 0, accuracy: 0.5)
    }
}
