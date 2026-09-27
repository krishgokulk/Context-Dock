// Context-DockTests/SafariPageActionsTests.swift
//
// Task 6: Safari's "Ask AI about this page" and "Save as Markdown" — listed and pinnable for
// Safari only, the question asked through the Corner's own ask path, the Markdown file named
// from the page and never overwriting, and a page SensitivePageGuard keeps DoraX out of
// refused by both.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Safari page actions")
struct SafariPageActionsTests {

    private static let safari = "com.apple.Safari"
    private static let ask = AdapterStarterActions.safariAskAboutPage
    private static let save = AdapterStarterActions.safariSaveAsMarkdown

    private static func page(
        _ url: String = "https://swift.org/documentation/", title: String = "Swift Documentation",
        text: String = "Swift is a general-purpose language.\n\n\n\nIt is fast."
    ) -> BrowserPageSnapshot {
        BrowserPageSnapshot(
            url: url, title: title, text: text,
            links: [SafariPageLink(url: "https://swift.org/install", text: "Install [beta]")])
    }

    // MARK: Listed and pinnable

    @Test("Both actions are Safari's starters, and no other app gets them")
    func safariOnly() {
        let safari = AdapterStarterActions.starters(for: Self.safari, appName: "Safari").map(\.id)
        #expect(safari.contains(Self.ask.id))
        #expect(safari.contains(Self.save.id))
        for (bundle, name) in [
            ("com.apple.TextEdit", "TextEdit"), ("com.google.Chrome", "Chrome"),
            ("com.example.none", "Nothing"),
        ] {
            let ids = AdapterStarterActions.starters(for: bundle, appName: name).map(\.id)
            #expect(!ids.contains(Self.ask.id))
            #expect(!ids.contains(Self.save.id))
        }
    }

    @Test("Both are pinnable as app actions, and neither asks for approval")
    func pinnable() {
        #expect(DockPinKind(appRow: .action(Self.ask)) == .appAction(id: Self.ask.id))
        #expect(DockPinKind(appRow: .action(Self.save)) == .appAction(id: Self.save.id))
        #expect(!Self.ask.requiresApproval)
        #expect(!Self.save.requiresApproval)
        #expect(Self.ask.type == .aiPrompt)
        #expect(Self.save.type == .savePageMarkdown)
    }

    @Test("The adapter contract accepts the built-in Markdown action with no payload")
    func contractAcceptsIt() {
        #expect(AdapterActionType.savePageMarkdown.riskLevel == .low)
        #expect(AdapterActionType(rawValue: "savePageMarkdown") == .savePageMarkdown)
    }

    // MARK: Ask AI about this page

    @Test("The question grounds a Safari turn on the open page, through the chat's own reader")
    @MainActor
    func theQuestionReadsThePage() {
        let plan = FrontmostAppTaskPlan.make(
            query: Self.ask.aiPromptTemplate ?? "", bundleId: Self.safari, appName: "Safari")
        #expect(plan.allows(.browserPage))
        #expect(plan.allowedToolNames.contains("read_page"))
    }

    @Test("A sensitive page refuses the question, with the guard's reason; an ordinary one does not")
    func askRefusal() {
        #expect(AppChatPromptModel.askRefusal(page: Self.page()) == nil)
        #expect(AppChatPromptModel.askRefusal(page: nil) == nil)
        let bank = AppChatPromptModel.askRefusal(page: Self.page("https://online.hsbc.co.uk/account"))
        #expect(bank?.contains("bank") == true)
        let token = AppChatPromptModel.askRefusal(
            page: Self.page("https://example.com/callback?access_token=eyJhbGciOiJIUzI1NiJ9"))
        #expect(token != nil)
    }

    // MARK: Save as Markdown

    @Test("The document: title heading, source, text with runs of blank lines closed, links")
    func markdownBody() {
        let md = PageMarkdownExport.markdown(for: Self.page())
        #expect(md.hasPrefix("# Swift Documentation\n\n"))
        #expect(md.contains("Source: <https://swift.org/documentation/>"))
        #expect(md.contains("Swift is a general-purpose language.\n\nIt is fast."))
        #expect(!md.contains("\n\n\n"))
        #expect(md.contains("## Links"))
        #expect(md.contains("- [Install [beta\\]](https://swift.org/install)"))
    }

    @Test("The file is named from the title, safely, falling back to the host")
    func fileName() {
        #expect(PageMarkdownExport.baseName(title: "Swift: A/B \"Guide\"?", url: "")
            == "Swift A B Guide")
        #expect(PageMarkdownExport.baseName(title: "  ", url: "https://swift.org/x") == "swift.org")
        #expect(PageMarkdownExport.baseName(title: "", url: "") == "Web page")
        #expect(PageMarkdownExport.baseName(title: String(repeating: "a", count: 300), url: "")
            .count == 100)
        #expect(PageMarkdownExport.baseName(title: "...hidden", url: "") == "hidden")
    }

    @Test("Never overwrites: Name.md, then Name 2.md, Name 3.md")
    func noOverwrite() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        var taken: Set<String> = []
        let first = PageMarkdownExport.freeURL(base: "Page", in: folder) { taken.contains($0.path) }
        #expect(first.lastPathComponent == "Page.md")
        taken = ["/tmp/x/Page.md", "/tmp/x/Page 2.md"]
        let third = PageMarkdownExport.freeURL(base: "Page", in: folder) { taken.contains($0.path) }
        #expect(third.lastPathComponent == "Page 3.md")
    }

    @Test("Saving writes the page, twice without overwriting; a sensitive page writes nothing")
    func saving() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageMarkdownExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .saved(let one) = PageMarkdownExport.save(Self.page(), to: folder) else {
            Issue.record("first save did not save")
            return
        }
        guard case .saved(let two) = PageMarkdownExport.save(Self.page(), to: folder) else {
            Issue.record("second save did not save")
            return
        }
        #expect(one.lastPathComponent == "Swift Documentation.md")
        #expect(two.lastPathComponent == "Swift Documentation 2.md")
        #expect(try String(contentsOf: one, encoding: .utf8).hasPrefix("# Swift Documentation"))

        let bank = PageMarkdownExport.save(
            Self.page("https://www.paypal.com/myaccount", title: "Summary"), to: folder)
        guard case .refused = bank else {
            Issue.record("a payment page was not refused: \(bank)")
            return
        }
        #expect(PageMarkdownExport.save(nil, to: folder) == .unreadable)
        #expect(PageMarkdownExport.save(Self.page(text: "  "), to: folder) == .unreadable)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Swift Documentation 2.md", "Swift Documentation.md"])
    }
}

@Suite("Corner asks an action's prompt")
@MainActor
struct CornerActionPromptTests {

    @Test("An AI-prompt action is asked through the Corner's own ask path, answered in its chat")
    func askedHere() {
        let conversation = AppChatConversation()
        let model = AppChatPromptModel(conversation: conversation)
        model.summon(app: "brew", bundleID: "cli://brew")
        var asked: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: .appChatPromptSubmitted, object: nil, queue: nil
        ) { note in
            if let query = note.userInfo?["query"] as? String { asked.append(query) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(model.askActionPrompt("  Summarise this page.  "))
        #expect(asked == ["Summarise this page."])
        #expect(model.phase == .chat)
        #expect(!model.askActionPrompt("   "))
    }
}
