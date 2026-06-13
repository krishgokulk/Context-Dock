import AppKit
import Foundation

extension LauncherView {
    func loadAllContactsAsResults() {
        let expectedQuery = searchState.query.trimmingCharacters(in: .whitespaces)
        Task {
            let allContacts = await contactManager.getAllContacts()

            await MainActor.run {
                let currentQuery = searchState.query.trimmingCharacters(in: .whitespaces)
                guard currentQuery == expectedQuery else { return }
                var contactResults: [SearchResult] = []

                for contact in allContacts.prefix(100) {
                    let fullName = contact.fullName.isEmpty ? "Unnamed Contact" : contact.fullName

                    let contactData = SearchResult.ContactData(
                        primaryEmail: contact.primaryEmail,
                        allEmails: contact.allEmails,
                        primaryPhone: contact.primaryPhone,
                        allPhones: contact.allPhones,
                        identifier: contact.identifier
                    )

                    contactResults.append(
                        SearchResult(
                            title: fullName,
                            subtitle: contact.subtitle,
                            icon: contact.image
                                ?? NSImage(
                                    systemSymbolName: "person.circle.fill",
                                    accessibilityDescription: nil
                                ),
                            action: {
                                contact.openInContacts()
                            },
                            type: .contact,
                            filePath: nil,
                            contactData: contactData
                        )
                    )
                }

                setPinnedResults(contactResults, title: "Contacts", excludeTypes: [.contact])
                print("✅ Loaded \(contactResults.count) contacts")
            }
        }
    }

    func loadPhotosAsResults() {
        loadSystemDataAsPinnedResults(
            query: "",
            types: [.photo],
            title: "Photos",
            perTypeLimit: 100,
            allowEmptyQuery: true,
            excludeTypes: [.photo]
        )
    }

    func setPinnedResults(
        _ results: [SearchResult],
        title: String,
        excludeTypes: Set<SearchResult.ResultType>
    ) {
        DispatchQueue.main.async {
            self.searchState.pinnedResults = results
            self.searchState.pinnedTitle = title
            self.searchState.pinnedTypesToExclude = excludeTypes
            if self.searchState.activeSmartQueryKey != nil {
                self.searchState.appPanelAllItems = results
            }
            self.performSearchWithoutSpotlight()
        }
    }

    func clearPinnedResults() {
        searchState.pinnedResults = []
        searchState.pinnedTitle = nil
        searchState.pinnedTypesToExclude = []
        searchState.appPanelAllItems = []
    }

    func loadSystemDataAsPinnedResults(
        query: String,
        types: Set<SystemDataType>,
        title: String,
        perTypeLimit: Int = 100,
        allowEmptyQuery: Bool = false,
        excludeTypes: Set<SearchResult.ResultType>
    ) {
        let expectedQuery = searchState.query.trimmingCharacters(in: .whitespaces)
        Task {
            let systemResults = await systemDataManager.searchAll(
                query: query,
                types: types,
                perTypeLimit: perTypeLimit,
                allowEmptyQuery: allowEmptyQuery
            )

            await MainActor.run {
                let currentQuery = searchState.query.trimmingCharacters(in: .whitespaces)
                guard currentQuery == expectedQuery || searchState.activeSmartQueryKey != nil else {
                    return
                }

                let results: [SearchResult] = systemResults.map { systemResult in
                    let resultType: SearchResult.ResultType
                    switch systemResult.type {
                    case .calendarEvent:
                        resultType = .calendarEvent
                    case .reminder:
                        resultType = .reminder
                    case .note:
                        resultType = .note
                    case .mail:
                        resultType = .mail
                    case .photo:
                        resultType = .photo
                    case .message:
                        resultType = .message
                    case .voiceRecording, .contact:
                        resultType = .file
                    }

                    return SearchResult(
                        title: systemResult.title,
                        subtitle: systemResult.subtitle,
                        icon: systemResult.icon,
                        action: { systemResult.open() },
                        score: 0.0,
                        type: resultType,
                        filePath: nil,
                        contactData: nil
                    )
                }

                setPinnedResults(results, title: title, excludeTypes: excludeTypes)
            }
        }
    }
}
