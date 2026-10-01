import Testing
@testable import Context_Dock

struct ReadBackComparisonTests {
    @Test func numbersMatchWithinOneStep() {
        #expect(ReadBackComparison.number(requested: "30", readBack: "30") == .matches)
        #expect(ReadBackComparison.number(requested: "30", readBack: "31") == .matches)
        #expect(ReadBackComparison.number(requested: "30", readBack: "29") == .matches)
        #expect(ReadBackComparison.number(requested: "30", readBack: "50") == .differs)
        #expect(ReadBackComparison.number(requested: "30", readBack: "50", tolerance: 25) == .matches)
        #expect(ReadBackComparison.number(requested: "30", readBack: "loud") == .notComparable)
    }

    @Test func togglesCompareAsOnOff() {
        #expect(ReadBackComparison.toggle(requested: "on", readBack: "true") == .matches)
        #expect(ReadBackComparison.toggle(requested: "dark", readBack: "1") == .matches)
        #expect(ReadBackComparison.toggle(requested: "off", readBack: "false") == .matches)
        #expect(ReadBackComparison.toggle(requested: "on", readBack: "off") == .differs)
        #expect(ReadBackComparison.toggle(requested: "dark", readBack: "light") == .differs)
        #expect(ReadBackComparison.toggle(requested: "on", readBack: "auto") == .notComparable)
    }

    @Test func enumerationsCompareWithinTheirSet() {
        let modes: Set<String> = ["light", "dark", "auto"]
        #expect(ReadBackComparison.enumeration(requested: "Dark", readBack: "dark", allowed: modes) == .matches)
        #expect(ReadBackComparison.enumeration(requested: "dark", readBack: "auto", allowed: modes) == .differs)
        #expect(ReadBackComparison.enumeration(requested: "dark", readBack: "purple", allowed: modes) == .notComparable)
    }

    @Test func freeTextIsNeverCompared() {
        #expect(ReadBackComparison.compare(requested: "Home WiFi", readBack: "Office") == .notComparable)
        #expect(ReadBackComparison.compare(requested: "Home WiFi", readBack: "home wifi") == .matches)
    }

    @Test func dispatcherRoutesByType() {
        #expect(ReadBackComparison.compare(requested: "30", readBack: "55") == .differs)
        #expect(ReadBackComparison.compare(requested: "off", readBack: "true") == .differs)
        #expect(ReadBackComparison.compare(requested: "dark", readBack: "true") == .matches)
    }

    @Test func mismatchMessageNamesBothValues() {
        let text = ReadBackComparison.mismatchMessage(name: "Volume", requested: "50", readBack: "0")
        #expect(text.contains("asked for 50"))
        #expect(text.contains("the Mac reports 0"))
    }
}
