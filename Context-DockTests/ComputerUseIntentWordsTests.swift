import XCTest

@testable import Context_Dock

final class ComputerUseIntentWordsTests: XCTestCase {

    func testTurningASettingOnOrOffIsAnAction() {
        XCTAssertTrue(ScopedRecordRead.actionWords.contains { "turn on the check spelling while typing option".contains($0) })
        XCTAssertTrue(ChatRouteResolver.isActionRequest("turn on the Check spelling while typing option"))
        XCTAssertTrue(ChatRouteResolver.isActionRequest("turn off smart quotes"))
    }

    func testQuestionsAboutSettingsStayQuestions() {
        XCTAssertFalse(ChatRouteResolver.isActionRequest("how do I turn on spell checking?"))
        XCTAssertFalse(ChatRouteResolver.isActionRequest("is spell checking turned on?"))
    }
}
