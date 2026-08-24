import Testing
@testable import Context_Dock

struct LocalInstallationCheckTests {
    @Test func parsesNaturalInstallationQuestions() {
        let first = LocalInstallationCheck.parse("check is llmbrain is installed on my system.")
        #expect(first?.displayName == "llmbrain")
        #expect(first?.executableNames.first == "llmbrain")

        let second = LocalInstallationCheck.parse("Is Visual Studio Code installed on my Mac?")
        #expect(second?.displayName == "Visual Studio Code")
        #expect(second?.executableNames.contains("visual-studio-code") == true)
    }

    @Test func ignoresNonInstallationRequests() {
        #expect(LocalInstallationCheck.parse("install llmbrain") == nil)
        #expect(LocalInstallationCheck.parse("what does llmbrain install?") == nil)
        #expect(LocalInstallationCheck.parse("open llmbrain") == nil)
    }
}
