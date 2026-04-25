//
//  AIShortcutMatcherTests.swift
//  Context-DockTests
//
//  Unit tests for AIShortcutMatcher.suggestShortcuts()
//  Verifies that context-aware scoring surfaces the most relevant shortcuts.
//

import XCTest
@testable import Context_Dock

final class AIShortcutMatcherTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a minimal SearchResult that can be used as input for suggestShortcuts.
    private func makeShortcut(title: String, subtitle: String = "") -> SearchResult {
        SearchResult(
            title: title,
            subtitle: subtitle,
            icon: nil,
            action: {},
            score: 0,
            type: .shortcut,
            filePath: nil,
            contactData: nil
        )
    }

    // MARK: - Context: none

    func testSuggestShortcuts_noneContext_returnsEmpty() async {
        let shortcuts = [
            makeShortcut(title: "Open File"),
            makeShortcut(title: "Summarize Text"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .none,
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        // With no context there are no context-match or app-match points → nothing scores > 0
        XCTAssertTrue(results.isEmpty, "No shortcuts should be suggested when context is .none")
    }

    // MARK: - Context: filesSelected

    func testSuggestShortcuts_fileContext_prefersFileKeywords() async {
        let shortcuts = [
            makeShortcut(title: "Convert files",       subtitle: "File conversion"),
            makeShortcut(title: "Summarize text",      subtitle: "AI summary"),
            makeShortcut(title: "Open browser",        subtitle: "Browse web"),
        ]
        let imageURL = URL(fileURLWithPath: "/tmp/photo.jpg")
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .filesSelected([imageURL]),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertTrue(results.first?.title == "Convert files",
                      "File-context should rank file-related shortcuts first")
    }

    func testSuggestShortcuts_imageFile_boostsImageKeywords() async {
        let shortcuts = [
            makeShortcut(title: "Resize image"),
            makeShortcut(title: "Compile code"),
        ]
        let imageURL = URL(fileURLWithPath: "/tmp/photo.png")
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .filesSelected([imageURL]),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Resize image",
                       "Image files should boost image-related shortcuts")
    }

    func testSuggestShortcuts_pdfFile_boostsPDFKeywords() async {
        let shortcuts = [
            makeShortcut(title: "Merge PDF"),
            makeShortcut(title: "Open browser"),
        ]
        let pdfURL = URL(fileURLWithPath: "/tmp/doc.pdf")
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .filesSelected([pdfURL]),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Merge PDF")
    }

    func testSuggestShortcuts_multipleFiles_batchBoost() async {
        let shortcuts = [
            makeShortcut(title: "Batch convert files"),
            makeShortcut(title: "View file"),
        ]
        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/file\($0).jpg") }
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .filesSelected(urls),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        // The "batch" keyword should score higher with multiple files
        XCTAssertEqual(results.first?.title, "Batch convert files")
    }

    // MARK: - Context: textSelected

    func testSuggestShortcuts_textContext_prefersTextKeywords() async {
        let shortcuts = [
            makeShortcut(title: "Format text"),
            makeShortcut(title: "Play music"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .textSelected("Some selected text here"),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Format text")
    }

    func testSuggestShortcuts_longText_prefersSummarize() async {
        let longText = Array(repeating: "word", count: 60).joined(separator: " ")
        let shortcuts = [
            makeShortcut(title: "Summarize content"),
            makeShortcut(title: "Count words"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .textSelected(longText),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Summarize content",
                       "Long text should boost 'summarize' keyword")
    }

    func testSuggestShortcuts_emptyText_returnsEmpty() async {
        let shortcuts = [makeShortcut(title: "Format text")]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .textSelected("   "),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertTrue(results.isEmpty,
                      "Whitespace-only text should not match any shortcuts")
    }

    // MARK: - Context: url

    func testSuggestShortcuts_urlContext_prefersURLKeywords() async {
        let shortcuts = [
            makeShortcut(title: "Open URL in browser"),
            makeShortcut(title: "Play video"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .url("https://example.com"),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Open URL in browser")
    }

    func testSuggestShortcuts_urlContext_prefersLinkKeyword() async {
        let shortcuts = [
            makeShortcut(title: "Copy link"),
            makeShortcut(title: "Open calendar"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .url("https://github.com/user/repo"),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Copy link")
    }

    // MARK: - Context: contactSelected

    func testSuggestShortcuts_contactContext_prefersContactKeywords() async {
        let shortcuts = [
            makeShortcut(title: "Send email to contact"),
            makeShortcut(title: "Open spreadsheet"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .contactSelected("Jane Doe"),
            frontmostApp: "",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Send email to contact")
    }

    // MARK: - Context: appFocused

    func testSuggestShortcuts_appContext_prefersAppNameMatch() async {
        let shortcuts = [
            makeShortcut(title: "Open new Safari window"),
            makeShortcut(title: "Encode base64"),
        ]
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .appFocused(name: "Safari", bundleID: "com.apple.Safari"),
            frontmostApp: "Safari",
            allShortcuts: shortcuts
        )
        XCTAssertEqual(results.first?.title, "Open new Safari window")
    }

    // MARK: - Limit enforcement

    func testSuggestShortcuts_respectsLimit() async {
        let shortcuts = (0..<20).map { makeShortcut(title: "Format text item \($0)") }
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .textSelected("hello world"),
            frontmostApp: "",
            allShortcuts: shortcuts,
            limit: 5
        )
        XCTAssertLessThanOrEqual(results.count, 5)
    }

    func testSuggestShortcuts_emptyShortcuts_returnsEmpty() async {
        let results = await AIShortcutMatcher.shared.suggestShortcuts(
            for: .textSelected("some text"),
            frontmostApp: "",
            allShortcuts: []
        )
        XCTAssertTrue(results.isEmpty)
    }
}
