import Testing
@testable import Context_Dock

struct ContactSearchRankingTests {
    @Test func ranksNicknameMatches() {
        let contacts = [
            makeContact(name: "Arumugam", family: "Appa Kulamangalam", phone: "98435 06175"),
            makeContact(name: "Gowri", family: "Sankar", nickname: "Akka", phone: "90000 00000"),
        ]

        let matches = ContactSearchManager.rankContacts(
            contacts,
            matching: "show contact info of akka",
            limit: 3
        )

        #expect(matches.first?.fullName == "Gowri Sankar")
    }

    @Test func ranksTypoTolerantNameMatches() {
        let contacts = [
            makeContact(name: "Priya", family: "Mam", phone: "111"),
            makeContact(name: "Gowri", family: "Sankar", phone: "222"),
        ]

        let matches = ContactSearchManager.rankContacts(
            contacts,
            matching: "find goeri contact info",
            limit: 3
        )

        #expect(matches.first?.fullName == "Gowri Sankar")
    }

    @Test func ignoresContactStopWords() {
        let tokens = ContactSearchManager.contactQueryTokens(from: "show contact info of Gowri")
        #expect(tokens == ["gowri"])
    }

    private func makeContact(
        name: String,
        family: String,
        nickname: String = "",
        organization: String = "",
        email: String = "",
        phone: String = ""
    ) -> ContactSearchManager.ContactResult {
        ContactSearchManager.ContactResult(
            identifier: "\(name)-\(family)",
            givenName: name,
            familyName: family,
            nickname: nickname,
            organizationName: organization,
            primaryEmail: email,
            allEmails: email.isEmpty ? [] : [email],
            primaryPhone: phone,
            allPhones: phone.isEmpty ? [] : [phone],
            image: nil
        )
    }
}
