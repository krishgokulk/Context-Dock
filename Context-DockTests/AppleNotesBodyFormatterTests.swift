import Foundation
import Testing

@testable import Context_Dock

// What Apple Notes actually stores.
//
// A note of fourteen Safari tabs was written correctly and rendered as one unbroken paragraph:
// Notes' `body` is HTML, and every newline in a plain-text body is collapsed by the renderer.
// The AppleScript succeeds, the note exists, and the formatting is gone with nothing reported.

struct AppleNotesBodyFormatterTests {

    @Test func linesSurviveAsLines() {
        let html = AppleNotesBodyFormatter.html(from: "First line\nSecond line")
        #expect(html.contains("<div>First line</div>"))
        #expect(html.contains("<div>Second line</div>"))
    }

    @Test func aBlankLineIsKeptAsSpacing() {
        let html = AppleNotesBodyFormatter.html(from: "Title\n\nBody")
        #expect(html.contains("<div><br></div>"))
    }

    @Test func aNumberedRunBecomesOneList() {
        let html = AppleNotesBodyFormatter.html(
            from: "Open tabs:\n1. Graphify\n2. Homebrew\n3. Freebuff")
        #expect(html.contains("<ol>"))
        #expect(html.contains("<li>Graphify</li>"))
        // Notes renumbers its own list; printing the original digits too would double them.
        #expect(!html.contains("<li>1. Graphify</li>"))
    }

    @Test func bulletsBecomeABulletedList() {
        let html = AppleNotesBodyFormatter.html(from: "- one\n- two")
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>one</li>"))
    }

    @Test func aBareURLBecomesALink() {
        // A note of links whose links cannot be clicked is a note of text about links.
        let html = AppleNotesBodyFormatter.html(from: "Graphify https://app.graphify.com/dorax")
        #expect(html.contains("<a href=\"https://app.graphify.com/dorax\">"))
    }

    @Test func aQueryStringSurvivesEscaping() {
        // The Indeed tab's URL carries `&` and `=`; escaped once, and in the form an href
        // needs, rather than twice or not at all.
        let html = AppleNotesBodyFormatter.html(
            from: "Job https://uk.indeed.com/viewjob?jk=549&tk=1k2&from=jobi2a")
        #expect(html.contains("jk=549&amp;tk=1k2&amp;from=jobi2a"))
        #expect(!html.contains("&amp;amp;"))
    }

    @Test func trailingPunctuationIsNotPartOfTheAddress() {
        let html = AppleNotesBodyFormatter.html(from: "See https://example.com.")
        #expect(html.contains("<a href=\"https://example.com\">"))
        #expect(html.contains("</a>."))
    }

    @Test func angleBracketsInTextCannotBecomeMarkup() {
        let html = AppleNotesBodyFormatter.html(from: "compare <div> with <span>")
        #expect(html.contains("&lt;div&gt;"))
        #expect(!html.contains("<div> with"))
    }

    @Test func bodyThatIsAlreadyMarkupIsLeftAlone() {
        // A caller that built its own HTML must not have it escaped into visible tags.
        let existing = "<div>Already written</div>"
        #expect(AppleNotesBodyFormatter.html(from: existing) == existing)
    }
}
