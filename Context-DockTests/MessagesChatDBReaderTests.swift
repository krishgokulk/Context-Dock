import Foundation
import Testing
@testable import Context_Dock

@Suite("Messages database body decoding")
struct MessagesChatDBReaderTests {
    private func hex(_ value: String) -> String {
        Data(value.utf8).map { String(format: "%02X", $0) }.joined()
    }

    @Test("Legacy message text remains preferred")
    func legacyText() {
        let text = MessagesChatDBReader.visibleText(
            textHex: hex("Amount due tomorrow"),
            attributedHex: hex("streamtyped NSMutableAttributedString ignored"))
        #expect(text == "Amount due tomorrow")
    }

    @Test("Visible text is recovered from a modern attributed body")
    func attributedBody() {
        let archive = "streamtyped\0NSMutableAttributedString\0NSString\0"
            + "An amount of INR 58,795.48 kept on hold has been removed.\0NSDictionary"
        let text = MessagesChatDBReader.visibleText(
            textHex: "", attributedHex: hex(archive))
        #expect(text.contains("INR 58,795.48"))
    }
}
