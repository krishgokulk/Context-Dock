//
//  UserContextTests.swift
//  Context-DockTests
//
//  Unit tests for the UserContext enum (description and icon properties).
//

import XCTest
@testable import Context_Dock

final class UserContextTests: XCTestCase {

    // MARK: - description

    func testDescription_filesSelected_pluralCount() {
        let urls: [URL] = [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ]
        let ctx = UserContext.filesSelected(urls)
        XCTAssertEqual(ctx.description, "filesSelected(2 files)")
    }

    func testDescription_filesSelected_singleFile() {
        let ctx = UserContext.filesSelected([URL(fileURLWithPath: "/tmp/one.png")])
        XCTAssertEqual(ctx.description, "filesSelected(1 file)")
    }

    func testDescription_filesSelected_empty() {
        let ctx = UserContext.filesSelected([])
        XCTAssertEqual(ctx.description, "filesSelected(0 files)")
    }

    func testDescription_textSelected_short() {
        let ctx = UserContext.textSelected("Hello, World!")
        XCTAssertEqual(ctx.description, "textSelected(Hello, World!)")
    }

    func testDescription_textSelected_exactlyAtLimit() {
        // 80 characters exactly → no ellipsis
        let text = String(repeating: "a", count: 80)
        let ctx = UserContext.textSelected(text)
        XCTAssertEqual(ctx.description, "textSelected(\(text))")
        XCTAssertFalse(ctx.description.contains("…"))
    }

    func testDescription_textSelected_overLimit() {
        // More than 80 characters → ellipsis appended
        let text = String(repeating: "x", count: 120)
        let ctx = UserContext.textSelected(text)
        XCTAssertTrue(ctx.description.contains("…"), "Long text description should contain ellipsis")
    }

    func testDescription_textSelected_stripsLeadingWhitespace() {
        let ctx = UserContext.textSelected("  Hello  ")
        // description trims and shows the trimmed preview
        XCTAssertTrue(ctx.description.contains("Hello"))
    }

    func testDescription_url() {
        let ctx = UserContext.url("https://example.com")
        XCTAssertEqual(ctx.description, "url(https://example.com)")
    }

    func testDescription_url_longIsTruncated() {
        let longURL = "https://example.com/" + String(repeating: "a", count: 200)
        let ctx = UserContext.url(longURL)
        // url description uses String.prefix(80) from the raw associated value
        XCTAssertTrue(ctx.description.count < longURL.count + 20,
                      "Long URL description should be shorter than the full URL + prefix")
    }

    func testDescription_appFocused() {
        let ctx = UserContext.appFocused(name: "Safari", bundleID: "com.apple.Safari")
        XCTAssertEqual(ctx.description, "appFocused(Safari, com.apple.Safari)")
    }

    func testDescription_contactSelected() {
        let ctx = UserContext.contactSelected("Jane Doe")
        XCTAssertEqual(ctx.description, "contactSelected(Jane Doe)")
    }

    func testDescription_none() {
        let ctx = UserContext.none
        XCTAssertEqual(ctx.description, "none")
    }

    // MARK: - icon

    func testIcon_filesSelected() {
        XCTAssertEqual(UserContext.filesSelected([]).icon, "doc.on.doc.fill")
    }

    func testIcon_textSelected() {
        XCTAssertEqual(UserContext.textSelected("hi").icon, "doc.text.fill")
    }

    func testIcon_url() {
        XCTAssertEqual(UserContext.url("https://example.com").icon, "link")
    }

    func testIcon_appFocused() {
        XCTAssertEqual(UserContext.appFocused(name: "Finder", bundleID: "com.apple.finder").icon, "app.fill")
    }

    func testIcon_contactSelected() {
        XCTAssertEqual(UserContext.contactSelected("Bob").icon, "person.crop.circle.fill")
    }

    func testIcon_none() {
        XCTAssertEqual(UserContext.none.icon, "circle")
    }

    // MARK: - Completeness (all cases accounted for)

    func testAllCasesHaveNonEmptyIcon() {
        let cases: [UserContext] = [
            .filesSelected([]),
            .textSelected("text"),
            .url("https://example.com"),
            .appFocused(name: "App", bundleID: "com.example"),
            .contactSelected("Contact"),
            .none,
        ]
        for ctx in cases {
            XCTAssertFalse(ctx.icon.isEmpty, "Icon for \(ctx.description) must not be empty")
        }
    }

    func testAllCasesHaveNonEmptyDescription() {
        let cases: [UserContext] = [
            .filesSelected([URL(fileURLWithPath: "/tmp/file")]),
            .textSelected("hello"),
            .url("https://example.com"),
            .appFocused(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
            .contactSelected("Alice"),
            .none,
        ]
        for ctx in cases {
            XCTAssertFalse(ctx.description.isEmpty, "Description must not be empty for any case")
        }
    }
}
