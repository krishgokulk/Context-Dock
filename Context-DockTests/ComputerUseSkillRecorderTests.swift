import XCTest

@testable import Context_Dock

final class ComputerUseSkillRecorderTests: XCTestCase {

    func testTooFewStepsMakesNoSkill() {
        XCTAssertNil(
            ComputerUseSkillRecorder.makeSkill(
                bundleID: "com.x", appName: "X", goal: "Export",
                steps: [LearnedStep(text: "click Button \"Export\"")]))
    }

    func testSkillIsAppScopedAndNamed() {
        let skill = ComputerUseSkillRecorder.makeSkill(
            bundleID: "com.x", appName: "X", goal: "Export as PDF",
            steps: [LearnedStep(text: "press menu File ▸ Export"), LearnedStep(text: "click Button \"Save\"")])
        XCTAssertEqual(skill?.adapterBundleId, "com.x")
        XCTAssertEqual(skill?.name, "Learned: Export as PDF")
        XCTAssertTrue(skill?.surfaceId.isEmpty ?? false)
        XCTAssertTrue(skill?.instructions.contains("1. press menu File ▸ Export") ?? false)
        XCTAssertFalse(skill?.isPinned ?? true)
    }

    func testUserContentIsNeverRecorded() {
        XCTAssertNil(
            ComputerUseSkillRecorder.describe(action: "click", role: "Row", label: "Invoice from Bob", isPixel: false))
        XCTAssertNil(
            ComputerUseSkillRecorder.describe(action: "click", role: "text (pixels)", label: "Hello", isPixel: true))
        let typed = ComputerUseSkillRecorder.describe(
            action: "type", role: "TextField", label: "Name", isPixel: false)
        XCTAssertEqual(typed, "type into TextField \"Name\" (the text from the request)")
    }
}
