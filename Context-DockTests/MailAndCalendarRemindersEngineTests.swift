import Testing
import Foundation
@testable import Context_Dock

@MainActor
struct MailAndCalendarRemindersEngineTests {

    @Test func mailCapabilitiesIncludeUnreadSearchSend() {
        let registry = CapabilityRegistry.shared
        AppleMailMCPCapabilities.register(in: registry)

        let unread = registry.capability(id: "mail.unread")
        #expect(unread != nil)
        #expect(unread?.appBundleID == "com.apple.mail")
        #expect(unread?.riskLevel == .low)

        let search = registry.capability(id: "mail.search")
        #expect(search != nil)
        #expect(search?.appBundleID == "com.apple.mail")
        #expect(search?.riskLevel == .low)
        #expect(search?.inputSchema.fields.contains(where: { $0.name == "query" }) == true)

        let send = registry.capability(id: "mail.send")
        #expect(send != nil)
        #expect(send?.appBundleID == "com.apple.mail")
        #expect(send?.riskLevel == .high)
        #expect(send?.riskLevel.requiresApproval == true)
        #expect(send?.inputSchema.fields.contains(where: { $0.name == "to" && $0.required }) == true)
        #expect(send?.inputSchema.fields.contains(where: { $0.name == "subject" && $0.required }) == true)
        #expect(send?.inputSchema.fields.contains(where: { $0.name == "body" && $0.required }) == true)
    }

    @Test func mailResolveRecipientDirectEmail() {
        let res = MailAutomation.resolveRecipient("founder@company.com")
        if case .resolved(let contact) = res {
            #expect(contact.handle == "founder@company.com")
            #expect(contact.name == "founder@company.com")
        } else {
            Issue.record("Expected direct email to resolve immediately")
        }
    }

    @Test func calendarCapabilitiesIncludeTodayEvents() {
        let registry = CapabilityRegistry.shared
        AppleCalendarMCPCapabilities.register(in: registry)

        let today = registry.capability(id: "calendar.today")
        #expect(today != nil)
        #expect(today?.appBundleID == "com.apple.iCal")
        #expect(today?.riskLevel == .low)

        let todayEvents = registry.capability(id: "calendar.todayEvents")
        #expect(todayEvents != nil)
        #expect(todayEvents?.appBundleID == "com.apple.iCal")
        #expect(todayEvents?.riskLevel == .low)
    }

    @Test func remindersCapabilitiesIncludeListAndCreate() {
        let registry = CapabilityRegistry.shared
        AppleRemindersMCPCapabilities.register(in: registry)

        let list = registry.capability(id: "reminders.list")
        #expect(list != nil)
        #expect(list?.appBundleID == "com.apple.reminders")
        #expect(list?.riskLevel == .low)

        let create = registry.capability(id: "reminders.create")
        #expect(create != nil)
        #expect(create?.appBundleID == "com.apple.reminders")
        #expect(create?.riskLevel == .medium)
        #expect(create?.inputSchema.fields.contains(where: { $0.name == "title" && $0.required }) == true)
    }

    @Test func agentToolRegistryContainsMailAndCalendarRemindersTools() {
        let registry = AgentToolRegistry.shared

        #expect(registry.tool(named: "read_unread_mail") != nil)
        #expect(registry.tool(named: "search_mail") != nil)

        let sendMail = registry.tool(named: "send_mail")
        #expect(sendMail != nil)
        #expect(sendMail?.required == ["to", "subject", "body"])

        #expect(registry.tool(named: "list_reminders") != nil)

        let createReminder = registry.tool(named: "create_reminder")
        #expect(createReminder != nil)
        #expect(createReminder?.required == ["title"])

        #expect(registry.tool(named: "get_today_events") != nil)
    }

    @Test func outboundGateClassifiesAllNewTools() {
        let registry = AgentToolRegistry.shared
        let unclassified = registry.allTools.map(\.name)
            .filter { !OutboundGate.isClassified(toolName: $0) }
        #expect(unclassified.isEmpty, "All tools must be classified in OutboundGate")

        #expect(OutboundGate.outboundTools.contains("send_mail"))
        #expect(OutboundGate.localTools.contains("read_unread_mail"))
        #expect(OutboundGate.localTools.contains("search_mail"))
        #expect(OutboundGate.localTools.contains("list_reminders"))
        #expect(OutboundGate.localTools.contains("create_reminder"))
        #expect(OutboundGate.localTools.contains("get_today_events"))
    }

    @Test func taskPlanIncludesAppropriateToolsForApps() {
        let mailPlan = FrontmostAppTaskPlan.make(
            query: "check my email",
            bundleId: "com.apple.mail",
            appName: "Mail"
        )
        #expect(mailPlan.allowedToolNames.contains("read_unread_mail"))
        #expect(mailPlan.allowedToolNames.contains("search_mail"))
        #expect(mailPlan.allowedToolNames.contains("send_mail"))

        let remindersPlan = FrontmostAppTaskPlan.make(
            query: "list my reminders",
            bundleId: "com.apple.reminders",
            appName: "Reminders"
        )
        #expect(remindersPlan.allowedToolNames.contains("list_reminders"))
        #expect(remindersPlan.allowedToolNames.contains("create_reminder"))

        let calendarPlan = FrontmostAppTaskPlan.make(
            query: "what is on my calendar today",
            bundleId: "com.apple.iCal",
            appName: "Calendar"
        )
        #expect(calendarPlan.allowedToolNames.contains("get_today_events"))
    }
}
