import Foundation
import Testing

@testable import Context_Dock

// MARK: - H3 #410: Selection-type scope

@Suite("SelectionTypeScope")
struct SelectionTypeScopeTests {

    // MARK: - Migration: old stores load unchanged

    @Test("SolvedSkill without selectionType decodes with nil selectionType")
    @MainActor func solvedSkillMigration() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","queryTemplate":"summarize {doc}",
         "nonSlotWords":["summarize"],"slots":[{"name":"doc","tokenFamily":"file"}],
         "toolCalls":[],"bundleId":"com.apple.finder","createdAt":0,"runCount":0,"successCount":0}
        """
        let skill = try JSONDecoder().decode(SolvedSkill.self, from: Data(json.utf8))
        #expect(skill.selectionType == nil)
        #expect(skill.selectionScope == nil)
    }

    @Test("AdapterSkill without selectionType decodes with empty selectionType")
    func adapterSkillMigration() throws {
        let json = """
        {"id":"s1","adapterBundleId":"com.apple.finder","name":"Old Skill",
         "instructions":"do something","version":"1.0","isEnabled":true}
        """
        let skill = try JSONDecoder().decode(AdapterSkill.self, from: Data(json.utf8))
        #expect(skill.selectionType == "")
        #expect(skill.scope == .app(bundleId: "com.apple.finder"))
    }

    // MARK: - SkillSelectionType.matches

    @Test("pdf type matches a PDF file path")
    func pdfMatchesPdfPath() {
        let ctx = SlotDerivationContext(
            selectedText: nil,
            selectedFilePaths: ["/Users/me/report.pdf"],
            appName: "Preview")
        #expect(SkillSelectionType.pdf.matches(context: ctx))
    }

    @Test("pdf type does not match a text file path")
    func pdfDoesNotMatchTxt() {
        let ctx = SlotDerivationContext(
            selectedText: nil,
            selectedFilePaths: ["/Users/me/notes.txt"],
            appName: "TextEdit")
        #expect(!SkillSelectionType.pdf.matches(context: ctx))
    }

    @Test("image type matches a PNG file path")
    func imageMatchesPng() {
        let ctx = SlotDerivationContext(
            selectedText: nil,
            selectedFilePaths: ["/Users/me/photo.png"],
            appName: "Photos")
        #expect(SkillSelectionType.image.matches(context: ctx))
    }

    @Test("text type matches selected text with no files")
    func textMatchesSelectedText() {
        let ctx = SlotDerivationContext(
            selectedText: "hello world",
            selectedFilePaths: [],
            appName: "Safari")
        #expect(SkillSelectionType.text.matches(context: ctx))
    }

    @Test("text type does not match when files are present even with selected text")
    func textDoesNotMatchWhenFilesPresent() {
        let ctx = SlotDerivationContext(
            selectedText: "hello",
            selectedFilePaths: ["/Users/me/doc.pdf"],
            appName: "Safari")
        #expect(!SkillSelectionType.text.matches(context: ctx))
    }

    @Test("file type matches any file path")
    func fileMatchesAnyFile() {
        let ctx = SlotDerivationContext(
            selectedText: nil,
            selectedFilePaths: ["/Users/me/data.csv"],
            appName: "Numbers")
        #expect(SkillSelectionType.file.matches(context: ctx))
    }

    // MARK: - Cross-app matching: PDF skill listed in non-Finder app

    @Test("PDF-scoped SolvedSkill listed in non-Finder app when PDF is attached")
    func pdfSkillListedWithPdfAttached() {
        let pdfSkill = SolvedSkill(
            queryTemplate: "summarize {doc}",
            nonSlotWords: ["summarize"],
            slots: [SolvedSkillSlot(name: "doc", tokenFamily: "file")],
            toolCalls: [],
            bundleId: "com.apple.finder",
            selectionType: "pdf")
        let mailBundle = "com.apple.mail"
        let ctx = SlotDerivationContext(
            selectedText: nil,
            selectedFilePaths: ["/Users/me/invoice.pdf"],
            appName: "Mail")

        let eligible = SolvedSkillStore.eligible(
            from: [pdfSkill], forBundle: mailBundle, context: ctx)
        #expect(eligible.contains { $0.id == pdfSkill.id })
    }

    @Test("PDF-scoped SolvedSkill NOT listed in non-Finder app without a PDF")
    func pdfSkillNotListedWithoutPdf() {
        let pdfSkill = SolvedSkill(
            queryTemplate: "summarize {doc}",
            nonSlotWords: ["summarize"],
            slots: [SolvedSkillSlot(name: "doc", tokenFamily: "file")],
            toolCalls: [],
            bundleId: "com.apple.finder",
            selectionType: "pdf")
        let mailBundle = "com.apple.mail"
        let ctx = SlotDerivationContext(
            selectedText: "just some text",
            selectedFilePaths: [],
            appName: "Mail")

        let eligible = SolvedSkillStore.eligible(
            from: [pdfSkill], forBundle: mailBundle, context: ctx)
        #expect(!eligible.contains { $0.id == pdfSkill.id })
    }

    // MARK: - AdapterSkill scope derivation

    @Test("AdapterSkill with selectionType pdf has scope .selection(.pdf)")
    func adapterSkillSelectionScope() {
        let skill = AdapterSkill(
            adapterBundleId: "com.apple.finder",
            name: "PDF helper",
            instructions: "do x",
            selectionType: "pdf")
        #expect(skill.scope == .selection(.pdf))
    }

    @Test("AdapterSkill with empty selectionType falls back to app scope")
    func adapterSkillEmptySelectionFallsBack() {
        let skill = AdapterSkill(
            adapterBundleId: "com.apple.finder",
            name: "Finder helper",
            instructions: "do x",
            selectionType: "")
        #expect(skill.scope == .app(bundleId: "com.apple.finder"))
    }
}
