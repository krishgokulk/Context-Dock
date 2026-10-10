import Foundation
import Testing

@testable import Context_Dock

/// A list extension's rows each have their own identity, even when the script gives two of
/// them the same id — Listening Ports names a row by its PID, and one process listens on
/// several ports (owner 2026-10-08: "the duplicate Listening Ports rows").
@MainActor
struct CustomListRowIdentityTests {
    private let output = """
        {"id":"1067","title":"ControlCe","badge":"port 5000"}
        {"id":"1067","title":"ControlCe","badge":"port 7000"}
        {"id":"1086","title":"rapportd","badge":"port 59901"}
        """

    @Test func rowsSharingAScriptIDAreStillDistinctRows() {
        let rows = CustomListProviderService.testParse(output)
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.map(\.badge) == ["port 5000", "port 7000", "port 59901"])
    }

    /// The script still gets back the id it wrote, so Enter kills the right process.
    @Test func theScriptsOwnIDIsWhatTheActionReceives() {
        let rows = CustomListProviderService.testParse(output)
        #expect(rows.map(\.actionID) == ["1067", "1067", "1086"])
        #expect(rows[0].id == "1067")
    }
}
