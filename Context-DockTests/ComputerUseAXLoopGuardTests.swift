import XCTest

@testable import Context_Dock

final class ComputerUseAXLoopGuardTests: XCTestCase {

    func testDistinctActionsProceed() {
        var g = AXLoopGuard()
        XCTAssertEqual(g.record(actionKey: "click|e1|"), .proceed)
        XCTAssertEqual(g.record(actionKey: "click|e2|"), .proceed)
        XCTAssertEqual(g.record(actionKey: "type|e3|hi"), .proceed)
    }

    func testThirdIdenticalActionStalls() {
        var g = AXLoopGuard()
        XCTAssertEqual(g.record(actionKey: "click|e1|"), .proceed)
        XCTAssertEqual(g.record(actionKey: "click|e1|"), .proceed)
        XCTAssertEqual(g.record(actionKey: "click|e1|"), .stalled)
    }

    func testBudgetExhausts() {
        var g = AXLoopGuard(maxSteps: 3)
        for i in 0..<3 { XCTAssertEqual(g.record(actionKey: "click|e\(i)|"), .proceed) }
        XCTAssertEqual(g.record(actionKey: "click|e9|"), .budgetExhausted)
    }
}
