import SwiftUI

// MARK: - Apple App Script Template Catalog
// Ready-to-use JXA/AppleScript templates for every scriptable Apple app.
// Each template includes:
//   • The script code (with built-in contact resolution, error handling)
//   • A ready-to-paste AI capability description
//   • The app key it belongs to

struct AppleScriptTemplate: Identifiable {
    let id = UUID()
    let appKey: String          // matches App Shortcuts app key (messages, mail, notes, etc.)
    let name: String            // script file name (no spaces)
    let displayName: String     // shown in picker
    let language: AppScriptLanguage
    let icon: String            // SF Symbol
    let code: String
    let aiCapability: String    // paste-ready text for "What does this script do?"
    let tags: [String]          // for search
}

// MARK: - Catalog

struct AppleAppScriptTemplates {

    static let all: [AppleScriptTemplate] = messages + mail + notes + reminders + calendar + contacts + finder + safari + music + facetime

    // MARK: Messages

    static let messages: [AppleScriptTemplate] = [
        .init(
            appKey: "messages",
            name: "send-message",
            displayName: "Send iMessage / SMS",
            language: .jxa,
            icon: "message.fill",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // send-message — ILauncher Messages tool
            // argv[0] = recipient (name, phone, or email)
            // argv[1] = message text
            // Contact lookup: if argv[0] looks like a name (not phone/email),
            // the script resolves it to a handle via the Contacts app automatically.

            function run(argv) {
                const input   = (argv[0] || "").trim()
                const text    = (argv[1] || "").trim()
                if (!input || !text) return "Error: recipient and message required"

                const handle = resolveContact(input)
                if (!handle) return "Error: could not find contact for: " + input

                const messages = Application("Messages")
                try {
                    // Prefer iMessage service, fall back to SMS
                    let service = null
                    try { service = messages.services.whose({ serviceType: "iMessage" })[0] } catch(_) {}
                    if (!service) service = messages.services[0]

                    const buddy = service.buddies.whose({ handle: handle })[0]
                    messages.send(text, { to: buddy })
                    return "Sent to " + input + " (" + handle + "): " + text
                } catch(e) {
                    // Fallback: try by handle directly
                    try {
                        const buddy2 = messages.buddies.whose({ handle: handle })[0]
                        messages.send(text, { to: buddy2 })
                        return "Sent (fallback) to " + handle + ": " + text
                    } catch(e2) {
                        return "Error sending: " + e2.message
                    }
                }
            }

            // Resolves a display name like "Salman Khan" to a phone/email handle.
            // Passes through values that already look like phone numbers or emails.
            function resolveContact(nameOrHandle) {
                if (looksLikeHandle(nameOrHandle)) return nameOrHandle
                const contacts = Application("Contacts")
                contacts.includeStandardAdditions = true
                const results = contacts.people.whose({
                    _or: [
                        { name: { _contains: nameOrHandle } },
                        { firstName: { _contains: nameOrHandle } },
                        { lastName:  { _contains: nameOrHandle } }
                    ]
                })
                if (results.length === 0) return null
                const person = results[0]
                // Prefer phone for iMessage, then email
                if (person.phones().length > 0) return person.phones[0].value()
                if (person.emails().length > 0) return person.emails[0].value()
                return null
            }

            function looksLikeHandle(s) {
                return s.includes("@") || /^[\\+\\d\\s\\-\\(\\)]{7,}$/.test(s)
            }
            """,
            aiCapability: "Sends an iMessage or SMS to any contact. Accepts a contact name (e.g. 'Salman Khan'), phone number, or email as the first argument, and the message text as the second. Automatically looks up the contact's handle from the Contacts app. Use for: 'send X to Y', 'message Y saying X', 'text Y: X'.",
            tags: ["send", "message", "sms", "imessage", "text", "chat"]
        ),

        .init(
            appKey: "messages",
            name: "get-unread-messages",
            displayName: "Get Unread Messages",
            language: .jxa,
            icon: "tray.and.arrow.down",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // get-unread-messages — ILauncher Messages tool
            // Returns a summary of recent unread messages

            function run(argv) {
                const limit = parseInt(argv[0]) || 10
                const messages = Application("Messages")
                let summary = []
                const chats = messages.chats()
                for (let i = 0; i < Math.min(chats.length, limit); i++) {
                    try {
                        const chat = chats[i]
                        const name = chat.name ? chat.name() : "Unknown"
                        const msgs = chat.messages()
                        if (msgs.length > 0) {
                            const last = msgs[msgs.length - 1]
                            summary.push(name + ": " + last.content())
                        }
                    } catch(e) {}
                }
                return summary.length > 0 ? summary.join("\\n") : "No recent messages"
            }
            """,
            aiCapability: "Returns recent Messages conversations and their last message. Use for: 'what are my latest messages', 'show unread messages', 'check messages'.",
            tags: ["unread", "messages", "inbox", "read"]
        )
    ]

    // MARK: Mail

    static let mail: [AppleScriptTemplate] = [
        .init(
            appKey: "mail",
            name: "send-email",
            displayName: "Send Email",
            language: .jxa,
            icon: "envelope.fill",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // send-email — ILauncher Mail tool
            // argv[0] = recipient name or email
            // argv[1] = subject
            // argv[2] = body text

            function run(argv) {
                const input   = (argv[0] || "").trim()
                const subject = (argv[1] || "(No subject)").trim()
                const body    = (argv[2] || "").trim()
                if (!input) return "Error: recipient required"

                const toAddress = resolveEmail(input)
                if (!toAddress) return "Error: could not find email for: " + input

                const mail = Application("Mail")
                mail.includeStandardAdditions = true
                const msg = mail.OutgoingMessage({
                    subject: subject,
                    content: body,
                    visible: true
                })
                mail.outgoingMessages.push(msg)
                const recipient = mail.ToRecipient({ address: toAddress })
                msg.toRecipients.push(recipient)
                msg.send()
                return "Email sent to " + input + " <" + toAddress + ">"
            }

            function resolveEmail(nameOrEmail) {
                if (nameOrEmail.includes("@")) return nameOrEmail
                const contacts = Application("Contacts")
                const results = contacts.people.whose({
                    _or: [
                        { name: { _contains: nameOrEmail } },
                        { firstName: { _contains: nameOrEmail } },
                        { lastName:  { _contains: nameOrEmail } }
                    ]
                })
                if (results.length === 0) return null
                const emails = results[0].emails()
                return emails.length > 0 ? emails[0].value() : null
            }
            """,
            aiCapability: "Sends an email via the Mail app. Accepts recipient name or email, subject, and body. Automatically resolves contact names to email addresses from Contacts. Use for: 'email X about Y', 'send email to X saying Y', 'share this via email with X'.",
            tags: ["send", "email", "mail", "compose"]
        ),

        .init(
            appKey: "mail",
            name: "get-unread-emails",
            displayName: "Get Unread Emails",
            language: .jxa,
            icon: "tray.and.arrow.down",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // get-unread-emails — ILauncher Mail tool
            function run(argv) {
                const limit = parseInt(argv[0]) || 10
                const mail  = Application("Mail")
                const inbox = mail.inbox
                const unread = inbox.messages.whose({ readStatus: false })()
                let lines = []
                for (let i = 0; i < Math.min(unread.length, limit); i++) {
                    const m = unread[i]
                    lines.push("From: " + m.sender() + "\\nSubject: " + m.subject() + "\\nDate: " + m.dateReceived())
                }
                return lines.length > 0 ? lines.join("\\n---\\n") : "No unread emails"
            }
            """,
            aiCapability: "Returns unread emails from Mail inbox with sender, subject, and date. Use for: 'check my email', 'any unread emails?', 'show inbox'.",
            tags: ["unread", "email", "inbox", "mail"]
        ),

        .init(
            appKey: "mail",
            name: "share-file-by-email",
            displayName: "Share File via Email",
            language: .jxa,
            icon: "square.and.arrow.up",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // share-file-by-email — ILauncher Mail + Finder tool
            // argv[0] = recipient name or email
            // argv[1] = file path (or $FILE from Finder selection)
            // argv[2] = message body (optional)

            function run(argv) {
                const input    = (argv[0] || "").trim()
                const filePath = (argv[1] || "").trim()
                const body     = (argv[2] || "Sharing this file with you.").trim()
                if (!input || !filePath) return "Error: recipient and file path required"

                const toAddress = resolveEmail(input)
                if (!toAddress) return "Error: could not find email for: " + input

                const fileName = filePath.split("/").pop()
                const mail = Application("Mail")
                const msg = mail.OutgoingMessage({
                    subject: "Sharing: " + fileName,
                    content: body,
                    visible: true
                })
                mail.outgoingMessages.push(msg)
                msg.toRecipients.push(mail.ToRecipient({ address: toAddress }))
                // Attach the file
                const attachment = mail.Attachment({ fileName: filePath })
                msg.content.attachments.push(attachment)
                msg.send()
                return "Sent " + fileName + " to " + input
            }

            function resolveEmail(nameOrEmail) {
                if (nameOrEmail.includes("@")) return nameOrEmail
                const contacts = Application("Contacts")
                const results = contacts.people.whose({ name: { _contains: nameOrEmail } })
                if (results.length === 0) return null
                const emails = results[0].emails()
                return emails.length > 0 ? emails[0].value() : null
            }
            """,
            aiCapability: "Shares the selected file as an email attachment. Accepts recipient name and optional message body. Resolves names from Contacts. Use for: 'share this file with X', 'email this to Y', 'send this document to X via email'.",
            tags: ["share", "attach", "file", "email", "send"]
        )
    ]

    // MARK: Notes

    static let notes: [AppleScriptTemplate] = [
        .init(
            appKey: "notes",
            name: "add-note",
            displayName: "Add Note",
            language: .jxa,
            icon: "note.text.badge.plus",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // add-note — ILauncher Notes tool
            // argv[0] = note title
            // argv[1] = note body (optional)
            // argv[2] = folder name (optional, defaults to "ILauncher")

            function run(argv) {
                const title  = (argv[0] || "New Note").trim()
                const body   = (argv[1] || "").trim()
                const folder = (argv[2] || "ILauncher").trim()

                const notes = Application("Notes")
                notes.includeStandardAdditions = true

                // Create folder if it doesn't exist
                let targetFolder
                try {
                    targetFolder = notes.folders.byName(folder)
                    targetFolder.name() // trigger access — throws if not found
                } catch(_) {
                    notes.make({ new: "folder", withProperties: { name: folder } })
                    targetFolder = notes.folders.byName(folder)
                }

                notes.make({
                    new: "note",
                    at: targetFolder,
                    withProperties: { name: title, body: "<b>" + title + "</b><br>" + body }
                })
                return "Note created: " + title
            }
            """,
            aiCapability: "Creates a new note in the Notes app. Accepts note title and optional body text. Saves to an 'ILauncher' folder by default. Use for: 'add a note about X', 'save X to notes', 'create note: X'.",
            tags: ["add", "create", "note", "save"]
        ),

        .init(
            appKey: "notes",
            name: "add-contact-to-notes",
            displayName: "Save Contact Details to Notes",
            language: .jxa,
            icon: "person.crop.rectangle",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // add-contact-to-notes — ILauncher Notes + Contacts tool
            // argv[0] = contact name to look up and save as a note

            function run(argv) {
                const name = (argv[0] || "").trim()
                if (!name) return "Error: contact name required"

                const contacts = Application("Contacts")
                const results = contacts.people.whose({
                    _or: [
                        { name: { _contains: name } },
                        { firstName: { _contains: name } },
                        { lastName:  { _contains: name } }
                    ]
                })
                if (results.length === 0) return "Contact not found: " + name

                const p = results[0]
                let lines = ["# " + p.name()]
                if (p.jobTitle && p.jobTitle() !== "") lines.push("Job: " + p.jobTitle())
                if (p.organization && p.organization() !== "") lines.push("Company: " + p.organization())
                p.phones().forEach(ph => lines.push("Phone: " + ph.value() + " (" + ph.label() + ")"))
                p.emails().forEach(em => lines.push("Email: " + em.value()))
                p.addresses().forEach(addr => {
                    const a = addr.value()
                    lines.push("Address: " + [a.street(), a.city(), a.state(), a.zip(), a.country()].filter(Boolean).join(", "))
                })
                if (p.birthday && p.birthday() !== null) lines.push("Birthday: " + p.birthday())
                if (p.note && p.note() !== "") lines.push("Note: " + p.note())

                const body = lines.join("\\n")
                const notes = Application("Notes")
                try {
                    const folder = notes.folders.byName("Contacts")
                    folder.name()
                } catch(_) {
                    notes.make({ new: "folder", withProperties: { name: "Contacts" } })
                }
                notes.make({
                    new: "note",
                    at: notes.folders.byName("Contacts"),
                    withProperties: { name: p.name(), body: body }
                })
                return "Saved " + p.name() + " to Notes/Contacts"
            }
            """,
            aiCapability: "Looks up a contact by name and saves all their details (phone, email, address, company, birthday) as a new note in Notes/Contacts folder. Use for: 'add Gowri's contact to notes', 'save X's details to notes', 'create note with contact info for X'.",
            tags: ["contact", "note", "save", "details", "info"]
        ),

        .init(
            appKey: "notes",
            name: "search-notes",
            displayName: "Search Notes",
            language: .jxa,
            icon: "magnifyingglass",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // search-notes — ILauncher Notes tool
            // argv[0] = search query

            function run(argv) {
                const query = (argv[0] || "").toLowerCase()
                const notes = Application("Notes")
                const all   = notes.notes()
                const hits  = all.filter(n => {
                    try {
                        return n.name().toLowerCase().includes(query) ||
                               n.plaintext().toLowerCase().includes(query)
                    } catch(_) { return false }
                }).slice(0, 10)
                if (hits.length === 0) return "No notes found for: " + query
                return hits.map(n => n.name() + "\\n" + n.plaintext().slice(0, 150)).join("\\n---\\n")
            }
            """,
            aiCapability: "Searches all notes for a keyword and returns matching note titles and previews. Use for: 'find note about X', 'search notes for Y', 'do I have a note on Z'.",
            tags: ["search", "find", "notes", "query"]
        )
    ]

    // MARK: Reminders

    static let reminders: [AppleScriptTemplate] = [

        // ─── UNIFIED ASSISTANT (recommended: add this ONE script) ───────────
        .init(
            appKey: "reminders",
            name: "reminders-assistant",
            displayName: "🧠 Reminders Assistant (All-in-One)",
            language: .jxa,
            icon: "checklist",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // reminders-assistant — ILauncher universal Reminders tool
            // argv[0] = full natural language query from the user
            //
            // Handles: add, complete, delete, search, list (today/overdue/all/upcoming),
            //          show by priority, show lists, stats/summary
            //
            // AI capability: add reminders with due date/time/priority/list, mark reminders
            // complete, delete reminders, search by keyword, list today's/overdue/upcoming/all
            // reminders, show high-priority tasks, list all reminder lists, get summary stats.
            // Pass the FULL user query as a single argument, e.g. "remind me to call mom tomorrow at 3pm"

            ObjC.import("Foundation")

            function run(argv) {
                const input = (argv[0] || "").trim()
                if (!input) return showToday()

                const low = input.toLowerCase()

                // ── INTENT DETECTION ────────────────────────────────────────────
                if (/^(add|create|new|remind me( to)?|set( a)? reminder|schedule|note to self)\\b/i.test(input))
                    return addReminder(input)

                if (/^(complete|done|finish|mark( as)?( done| complete| finished)?|check off|tick off)\\b/i.test(input))
                    return completeReminder(input)

                if (/^(delete|remove|cancel|clear|discard)\\b/i.test(input))
                    return deleteReminder(input)

                if (/^(search|find|look for|show me|filter)\\b/i.test(input))
                    return searchReminders(input)

                if (/\\boverdue\\b/i.test(low))   return showOverdue()
                if (/\\btoday\\b/i.test(low))     return showToday()
                if (/\\bupcoming|next \\d+ days?\\b/i.test(low)) {
                    const m = low.match(/next (\\d+) days?/)
                    return showUpcoming(m ? parseInt(m[1]) : 7)
                }
                if (/\\bhigh.?priority|urgent|important\\b/i.test(low)) return showHighPriority()
                if (/\\blists?\\b/i.test(low) && !/add|new|create/i.test(low)) return showLists()
                if (/\\bstats?|summary|count|how many\\b/i.test(low)) return getStats()
                if (/\\ball reminders?|show all|list all\\b/i.test(low)) return showAll()
                if (/\\blist\\b/i.test(low) || low === "show") return showAll()

                // Default: treat as "add reminder"
                return addReminder("add " + input)
            }

            // ── DATE / TIME / PRIORITY PARSING ──────────────────────────────

            function parseDate(text) {
                const now = new Date()
                const low = text.toLowerCase()
                if (/\\btoday\\b/.test(low)) return now
                if (/\\btomorrow\\b/.test(low)) { const d = new Date(now); d.setDate(d.getDate()+1); return d }
                if (/\\bday after tomorrow\\b/.test(low)) { const d = new Date(now); d.setDate(d.getDate()+2); return d }

                const weekdays = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
                for (let i = 0; i < weekdays.length; i++) {
                    if (low.includes(weekdays[i])) {
                        const d = new Date(now)
                        const diff = (i - d.getDay() + 7) % 7 || 7
                        d.setDate(d.getDate() + diff)
                        return d
                    }
                }

                const inM = low.match(/in (\\d+) (day|week|month)s?/)
                if (inM) {
                    const d = new Date(now); const n = parseInt(inM[1])
                    if (inM[2]==="day")   d.setDate(d.getDate()+n)
                    if (inM[2]==="week")  d.setDate(d.getDate()+n*7)
                    if (inM[2]==="month") d.setMonth(d.getMonth()+n)
                    return d
                }

                if (/next week/.test(low))  { const d = new Date(now); d.setDate(d.getDate()+7); return d }
                if (/next month/.test(low)) { const d = new Date(now); d.setMonth(d.getMonth()+1); return d }

                const months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
                for (let i = 0; i < months.length; i++) {
                    const m = low.match(new RegExp(months[i]+"\\\\s+(\\\\d{1,2})"))
                    if (m) {
                        const d = new Date(now.getFullYear(), i, parseInt(m[1]))
                        if (d < now) d.setFullYear(d.getFullYear()+1)
                        return d
                    }
                }

                const iso = low.match(/(\\d{4}-\\d{2}-\\d{2})/)
                if (iso) { const d = new Date(iso[1]); if (!isNaN(d)) return d }

                const slash = low.match(/(\\d{1,2})\\/(\\d{1,2})/)
                if (slash) {
                    const d = new Date(now.getFullYear(), parseInt(slash[1])-1, parseInt(slash[2]))
                    if (d < now) d.setFullYear(d.getFullYear()+1)
                    return d
                }
                return null
            }

            function parseTime(text) {
                const m = text.toLowerCase().match(/at\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?/)
                if (m) {
                    let h = parseInt(m[1]); const min = m[2] ? parseInt(m[2]) : 0; const ampm = m[3]
                    if (ampm==="pm" && h<12) h+=12
                    if (ampm==="am" && h===12) h=0
                    return { h, min }
                }
                const m2 = text.toLowerCase().match(/(\\d{1,2}):(\\d{2})\\s*(am|pm)?/)
                if (m2) {
                    let h = parseInt(m2[1]); const min = parseInt(m2[2]); const ampm = m2[3]
                    if (ampm==="pm" && h<12) h+=12
                    if (ampm==="am" && h===12) h=0
                    return { h, min }
                }
                return null
            }

            function parsePriority(text) {
                const low = text.toLowerCase()
                if (/\\b(high|urgent|important|asap|critical)\\b/.test(low)) return 1
                if (/\\b(medium|moderate|normal)\\b/.test(low)) return 5
                if (/\\b(low|minor|someday)\\b/.test(low)) return 9
                return 0
            }

            function parseList(text) {
                const app   = Application("Reminders")
                const low   = text.toLowerCase()
                const lists = app.lists()
                for (const l of lists) {
                    const ln = l.name().toLowerCase()
                    if (low.includes("in "+ln) || low.includes("to "+ln) || low.includes("list "+ln))
                        return l
                }
                return app.defaultList()
            }

            // ── OPERATIONS ──────────────────────────────────────────────────

            function addReminder(input) {
                const app  = Application("Reminders")
                // Strip command prefix
                const body = input.replace(/^(add|create|new|remind me( to)?|set( a)? reminder( for| to)?|schedule|note to self)\\s*/i, "")

                // Extract title = text up to first date/priority/list keyword
                const kw = /\\b(due|by|before|on|at|in|next|this|tomorrow|today|monday|tuesday|wednesday|thursday|friday|saturday|sunday|high|low|medium|urgent|priority|list|note:|notes?)\\b/i
                const ki = body.search(kw)
                const title = (ki > 0 ? body.slice(0, ki) : body).trim().replace(/[,!]+$/, "")
                if (!title) return "Please provide a reminder title."

                const priority = parsePriority(input)
                const list     = parseList(input)

                let dueDate = parseDate(input)
                const t = parseTime(input)
                if (dueDate && t) { dueDate.setHours(t.h, t.min, 0, 0) }
                else if (dueDate) { dueDate.setHours(9, 0, 0, 0) }   // default 9 AM

                const props = { name: title }
                if (dueDate)    { props.dueDate = dueDate; props.remindMeDate = dueDate }
                if (priority>0) { props.priority = priority }

                const notesM = input.match(/\\bnotes?:\\s*(.+?)(?:\\s+due|\\s+priority|\\s+list|$)/i)
                if (notesM) props.body = notesM[1].trim()

                app.make({ new: "reminder", at: list, withProperties: props })

                let out = "✅ Added: \\"" + title + "\\""
                if (dueDate)    out += "\\n📅 Due: " + dueDate.toLocaleString()
                if (priority===1) out += "\\n🔴 High priority"
                if (priority===5) out += "\\n🟡 Medium priority"
                if (priority===9) out += "\\n🟢 Low priority"
                out += "\\n📋 List: " + list.name()
                return out
            }

            function completeReminder(input) {
                const query = input.replace(/^(complete|done|finish|mark( as)?( done| complete| finished)?|check off|tick off)\\s*/i, "").trim()
                if (!query) return "Which reminder should I mark complete?"
                const app = Application("Reminders")
                let found = null
                for (const l of app.lists()) {
                    for (const r of l.reminders.whose({ completed: false })()) {
                        if (r.name().toLowerCase().includes(query.toLowerCase())) { found = r; break }
                    }
                    if (found) break
                }
                if (!found) return "❌ No pending reminder matching \\"" + query + "\\""
                const name = found.name()
                found.completed = true
                return "✅ Completed: \\"" + name + "\\""
            }

            function deleteReminder(input) {
                const query = input.replace(/^(delete|remove|cancel|clear|discard)\\s*/i, "").trim()
                if (!query) return "Which reminder should I delete?"
                const app = Application("Reminders")
                let found = null
                for (const l of app.lists()) {
                    for (const r of l.reminders()) {
                        if (r.name().toLowerCase().includes(query.toLowerCase())) { found = r; break }
                    }
                    if (found) break
                }
                if (!found) return "❌ No reminder found matching \\"" + query + "\\""
                const name = found.name()
                found.delete()
                return "🗑️ Deleted: \\"" + name + "\\""
            }

            function searchReminders(input) {
                const query = input.replace(/^(search|find|look for|show me|filter)\\s*/i, "").trim()
                if (!query) return "What should I search for?"
                const app = Application("Reminders"); const qLow = query.toLowerCase()
                const rows = []
                for (const l of app.lists()) {
                    for (const r of l.reminders()) {
                        if (r.name().toLowerCase().includes(qLow)) {
                            const icon = r.completed() ? "✅" : "⭕"
                            let line = icon + " " + r.name() + "  [" + l.name() + "]"
                            try { const d = r.dueDate(); if(d) line += " — " + new Date(d).toLocaleDateString() } catch(_){}
                            rows.push(line)
                        }
                    }
                }
                if (!rows.length) return "No reminders found for \\"" + query + "\\""
                return "🔍 " + rows.length + " result(s):\\n" + rows.join("\\n")
            }

            function showToday() {
                const app = Application("Reminders"); const now = new Date()
                const s = new Date(now.getFullYear(),now.getMonth(),now.getDate())
                const e = new Date(s.getTime()+86400000)
                const rows = []
                for (const l of app.lists()) {
                    for (const r of l.reminders.whose({ completed: false })()) {
                        try {
                            const d = r.dueDate()
                            if (d && new Date(d) >= s && new Date(d) < e)
                                rows.push("⭕ " + r.name() + " — " + new Date(d).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"}) + "  [" + l.name() + "]")
                        } catch(_){}
                    }
                }
                if (!rows.length) return "🎉 Nothing due today!"
                return "📅 Today (" + rows.length + "):\\n" + rows.join("\\n")
            }

            function showOverdue() {
                const app = Application("Reminders"); const now = new Date()
                const rows = []
                for (const l of app.lists()) {
                    for (const r of l.reminders.whose({ completed: false })()) {
                        try {
                            const d = r.dueDate()
                            if (d && new Date(d) < now)
                                rows.push("🔴 " + r.name() + " — was due " + new Date(d).toLocaleDateString() + "  [" + l.name() + "]")
                        } catch(_){}
                    }
                }
                if (!rows.length) return "✅ No overdue reminders!"
                return "⚠️ Overdue (" + rows.length + "):\\n" + rows.join("\\n")
            }

            function showUpcoming(days) {
                const app = Application("Reminders"); const now = new Date()
                const end = new Date(now.getTime() + days*86400000)
                const rows = []
                for (const l of app.lists()) {
                    for (const r of l.reminders.whose({ completed: false })()) {
                        try {
                            const d = r.dueDate()
                            if (d && new Date(d) >= now && new Date(d) <= end)
                                rows.push({ text: "⭕ " + r.name() + " — " + new Date(d).toLocaleDateString() + "  [" + l.name() + "]", d: new Date(d) })
                        } catch(_){}
                    }
                }
                rows.sort((a,b)=>a.d-b.d)
                if (!rows.length) return "✅ Nothing due in the next " + days + " days."
                return "📅 Next " + days + " days (" + rows.length + "):\\n" + rows.map(r=>r.text).join("\\n")
            }

            function showAll() {
                const app = Application("Reminders")
                const rows = []
                for (const l of app.lists()) {
                    for (const r of l.reminders.whose({ completed: false })()) {
                        let line = "⭕ " + r.name() + "  [" + l.name() + "]"
                        try { const d = r.dueDate(); if(d) line += " — " + new Date(d).toLocaleDateString() } catch(_){}
                        rows.push(line)
                    }
                }
                if (!rows.length) return "✅ All clear — no pending reminders!"
                return "All pending (" + rows.length + "):\\n" + rows.join("\\n")
            }

            function showHighPriority() {
                const app = Application("Reminders")
                const rows = []
                for (const l of app.lists()) {
                    for (const r of l.reminders.whose({ completed: false })()) {
                        try {
                            if (r.priority() === 1) {
                                let line = "🔴 " + r.name() + "  [" + l.name() + "]"
                                try { const d = r.dueDate(); if(d) line += " — " + new Date(d).toLocaleDateString() } catch(_){}
                                rows.push(line)
                            }
                        } catch(_){}
                    }
                }
                if (!rows.length) return "No high-priority reminders."
                return "🔴 High priority (" + rows.length + "):\\n" + rows.join("\\n")
            }

            function showLists() {
                const app = Application("Reminders"); const lists = app.lists()
                let out = "📋 Lists (" + lists.length + "):\\n"
                for (const l of lists) {
                    const count = l.reminders.whose({ completed: false })().length
                    out += "• " + l.name() + " — " + count + " pending\\n"
                }
                return out.trim()
            }

            function getStats() {
                const app = Application("Reminders"); const now = new Date()
                const todayS = new Date(now.getFullYear(),now.getMonth(),now.getDate())
                const todayE = new Date(todayS.getTime()+86400000)
                let total=0, done=0, overdue=0, today=0
                for (const l of app.lists()) {
                    for (const r of l.reminders()) {
                        total++
                        if (r.completed()) { done++; continue }
                        try {
                            const d = r.dueDate()
                            if (d) {
                                const dd = new Date(d)
                                if (dd < now) overdue++
                                else if (dd >= todayS && dd < todayE) today++
                            }
                        } catch(_){}
                    }
                }
                return "📊 Summary\\n• Total: " + total + "\\n• Pending: " + (total-done) + "\\n• Completed: " + done + "\\n• Due today: " + today + "\\n• Overdue: " + overdue + "\\n• Lists: " + app.lists().length
            }
            """,
            aiCapability: "Universal Reminders assistant. Call with the user's full natural language query. Handles: adding reminders with smart date/time/priority/list parsing (today, tomorrow, next Monday, in 3 days, at 3pm, high priority, in Work list), completing reminders by name, deleting reminders, searching by keyword, listing today's/overdue/upcoming/all/high-priority reminders, showing all lists with counts, and summary stats. Just pass the raw user query.",
            tags: ["add","complete","delete","search","list","today","overdue","upcoming","priority","stats","reminders","tasks","todo","universal"]
        ),

        // ─── INDIVIDUAL SCRIPTS (kept for backward compat / single-use) ────
        .init(
            appKey: "reminders",
            name: "add-reminder",
            displayName: "Add Reminder",
            language: .jxa,
            icon: "checklist.checked",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // add-reminder — ILauncher Reminders tool
            // argv[0] = reminder text
            // argv[1] = due date/time string, e.g. "2026-03-17T16:00:00" or "today at 4pm"
            // argv[2] = list name (optional, defaults to "Reminders")

            function run(argv) {
                const text    = (argv[0] || "").trim()
                const dueStr  = (argv[1] || "").trim()
                const listName = (argv[2] || "Reminders").trim()
                if (!text) return "Error: reminder text required"

                const app  = Application("Reminders")
                app.includeStandardAdditions = true

                let targetList
                try {
                    targetList = app.lists.byName(listName)
                    targetList.name() // throws if not found
                } catch(_) {
                    app.make({ new: "list", withProperties: { name: listName } })
                    targetList = app.lists.byName(listName)
                }

                const props = { name: text }
                if (dueStr) {
                    // Try ISO8601 first
                    const isoDate = new Date(dueStr)
                    if (!isNaN(isoDate)) {
                        props.dueDate = isoDate
                        props.remindMeDate = isoDate
                    }
                }

                app.make({ new: "reminder", at: targetList, withProperties: props })
                const due = props.dueDate ? " due " + props.dueDate.toLocaleString() : ""
                return "Reminder set: " + text + due
            }
            """,
            aiCapability: "Creates a reminder in the Reminders app with optional due date and time. Accepts natural language dates like '2026-03-17T16:00:00'. Use for: 'remind me to X at Y', 'add reminder: X by Y', 'set reminder for X'.",
            tags: ["add", "reminder", "due", "todo", "task"]
        ),

        .init(
            appKey: "reminders",
            name: "list-reminders",
            displayName: "List Reminders",
            language: .jxa,
            icon: "list.bullet",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // list-reminders — ILauncher Reminders tool
            // argv[0] = filter: "today", "overdue", "all" (default: all incomplete)

            function run(argv) {
                const filter = (argv[0] || "all").toLowerCase()
                const app    = Application("Reminders")
                const now    = new Date()
                const todayEnd = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59)

                let reminders = app.reminders.whose({ completed: false })()
                if (filter === "today") {
                    reminders = reminders.filter(r => {
                        try { const d = r.dueDate(); return d && d <= todayEnd } catch(_) { return false }
                    })
                } else if (filter === "overdue") {
                    reminders = reminders.filter(r => {
                        try { const d = r.dueDate(); return d && d < now } catch(_) { return false }
                    })
                }
                if (reminders.length === 0) return "No reminders found"
                return reminders.slice(0, 20).map(r => {
                    let line = "• " + r.name()
                    try { const d = r.dueDate(); if (d) line += " — " + d.toLocaleString() } catch(_) {}
                    return line
                }).join("\\n")
            }
            """,
            aiCapability: "Lists incomplete reminders. Supports filter: 'today' (due today), 'overdue', 'all'. Use for: 'show my reminders', 'what do I need to do today', 'list overdue tasks'.",
            tags: ["list", "reminders", "todo", "tasks", "overdue", "today"]
        )
    ]

    // MARK: Calendar

    static let calendar: [AppleScriptTemplate] = [
        .init(
            appKey: "calendar",
            name: "add-event",
            displayName: "Add Calendar Event",
            language: .jxa,
            icon: "calendar.badge.plus",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // add-event — ILauncher Calendar tool
            // argv[0] = event title
            // argv[1] = start datetime ISO8601 e.g. "2026-03-17T14:00:00"
            // argv[2] = end datetime ISO8601 (optional, defaults to +1 hour)
            // argv[3] = location (optional)
            // argv[4] = notes (optional)

            function run(argv) {
                const title    = (argv[0] || "").trim()
                const startStr = (argv[1] || "").trim()
                const endStr   = (argv[2] || "").trim()
                const location = (argv[3] || "").trim()
                const notes    = (argv[4] || "").trim()
                if (!title || !startStr) return "Error: title and start date required"

                const startDate = new Date(startStr)
                const endDate   = endStr ? new Date(endStr) : new Date(startDate.getTime() + 3600000)
                if (isNaN(startDate)) return "Error: invalid start date: " + startStr

                const cal = Application("Calendar")
                cal.includeStandardAdditions = true
                const calendars = cal.calendars()
                const target    = calendars[0] // first/default calendar

                const props = {
                    summary: title,
                    startDate: startDate,
                    endDate: endDate
                }
                if (location) props.location = location
                if (notes)    props.description = notes

                cal.make({ new: "event", at: target, withProperties: props })
                return "Event created: " + title + " on " + startDate.toLocaleString()
            }
            """,
            aiCapability: "Creates a new calendar event. Accepts title, start datetime (ISO8601), optional end datetime, location, and notes. Use for: 'schedule X at Y', 'add event X on Y at Z', 'create meeting: X'.",
            tags: ["add", "calendar", "event", "schedule", "meeting"]
        ),

        .init(
            appKey: "calendar",
            name: "list-today-events",
            displayName: "List Today's Events",
            language: .jxa,
            icon: "calendar",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // list-today-events — ILauncher Calendar tool

            function run(argv) {
                const cal  = Application("Calendar")
                const now  = new Date()
                const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate())
                const todayEnd   = new Date(todayStart.getTime() + 86400000)

                let events = []
                cal.calendars().forEach(calendar => {
                    try {
                        calendar.events().forEach(ev => {
                            try {
                                const start = ev.startDate()
                                if (start >= todayStart && start < todayEnd) {
                                    events.push({
                                        title: ev.summary(),
                                        start: start,
                                        location: ev.location ? ev.location() : ""
                                    })
                                }
                            } catch(_) {}
                        })
                    } catch(_) {}
                })

                events.sort((a, b) => a.start - b.start)
                if (events.length === 0) return "No events today"
                return events.map(e => {
                    let s = e.start.toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"}) + " — " + e.title
                    if (e.location) s += " @ " + e.location
                    return s
                }).join("\\n")
            }
            """,
            aiCapability: "Lists all calendar events for today, sorted by time. Use for: 'what's on my calendar today', 'show today's schedule', 'any meetings today'.",
            tags: ["today", "calendar", "events", "schedule", "meetings"]
        )
    ]

    // MARK: Contacts

    static let contacts: [AppleScriptTemplate] = [
        .init(
            appKey: "contacts",
            name: "find-contact",
            displayName: "Find Contact",
            language: .jxa,
            icon: "person.fill.viewfinder",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // find-contact — ILauncher Contacts tool
            // argv[0] = name to search

            function run(argv) {
                const query = (argv[0] || "").trim()
                if (!query) return "Error: name required"

                const contacts = Application("Contacts")
                const results  = contacts.people.whose({
                    _or: [
                        { name: { _contains: query } },
                        { firstName: { _contains: query } },
                        { lastName:  { _contains: query } }
                    ]
                })

                if (results.length === 0) return "No contact found: " + query
                return results.slice(0, 5).map(p => {
                    let info = p.name()
                    if (p.organization && p.organization() !== "") info += " — " + p.organization()
                    p.phones().forEach(ph => info += "\\n  📞 " + ph.value() + " (" + ph.label() + ")")
                    p.emails().forEach(em => info += "\\n  ✉️ "  + em.value())
                    return info
                }).join("\\n\\n")
            }
            """,
            aiCapability: "Finds a contact by name and shows their phone numbers and email addresses. Use for: 'find X's number', 'what's X's email', 'look up contact X', 'show details for X'.",
            tags: ["find", "contact", "search", "phone", "email"]
        ),

        .init(
            appKey: "contacts",
            name: "add-contact",
            displayName: "Add New Contact",
            language: .jxa,
            icon: "person.badge.plus",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // add-contact — ILauncher Contacts tool
            // argv[0] = full name (or "First Last")
            // argv[1] = phone number
            // argv[2] = email address
            // argv[3] = company name (optional)

            function run(argv) {
                const fullName = (argv[0] || "").trim()
                const phone    = (argv[1] || "").trim()
                const email    = (argv[2] || "").trim()
                const company  = (argv[3] || "").trim()
                if (!fullName) return "Error: name required"

                const nameParts = fullName.split(" ")
                const firstName = nameParts[0] || ""
                const lastName  = nameParts.slice(1).join(" ") || ""

                const contacts = Application("Contacts")
                const props = { firstName: firstName, lastName: lastName }
                if (company) props.organization = company

                const person = contacts.make({ new: "person", withProperties: props })

                if (phone) {
                    contacts.make({
                        new: "phone",
                        at: person.phones,
                        withProperties: { value: phone, label: "mobile" }
                    })
                }
                if (email) {
                    contacts.make({
                        new: "email",
                        at: person.emails,
                        withProperties: { value: email, label: "work" }
                    })
                }
                contacts.save()
                return "Contact added: " + fullName + (phone ? " " + phone : "") + (email ? " " + email : "")
            }
            """,
            aiCapability: "Creates a new contact with name, phone, email, and optional company. Use for: 'add contact X with phone Y', 'save Gowri as contact with email Z', 'create new contact: name X phone Y email Z'.",
            tags: ["add", "create", "contact", "new", "save"]
        )
    ]

    // MARK: Finder

    static let finder: [AppleScriptTemplate] = [
        .init(
            appKey: "finder",
            name: "share-file-via-email",
            displayName: "Share Selected File via Email",
            language: .jxa,
            icon: "square.and.arrow.up",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // share-file-via-email — ILauncher Finder tool
            // $FILE / argv[0] = selected file path
            // argv[1] = recipient name or email
            // Opens a compose window with the file attached

            function run(argv) {
                const filePath  = (argv[0] || "").trim()
                const recipient = (argv[1] || "").trim()
                if (!filePath) return "Error: file path required"

                const toAddress = recipient ? resolveEmail(recipient) : ""
                const fileName  = filePath.split("/").pop()

                const mail = Application("Mail")
                const msg  = mail.OutgoingMessage({
                    subject: "Sharing: " + fileName,
                    content: "Please find the attached file.",
                    visible: true
                })
                mail.outgoingMessages.push(msg)
                if (toAddress) {
                    msg.toRecipients.push(mail.ToRecipient({ address: toAddress }))
                }
                const attach = mail.Attachment({ fileName: filePath })
                msg.content.attachments.push(attach)
                Application("Mail").activate()
                return "Compose window opened with " + fileName + (toAddress ? " to " + toAddress : "")
            }

            function resolveEmail(nameOrEmail) {
                if (nameOrEmail.includes("@")) return nameOrEmail
                const contacts = Application("Contacts")
                const results  = contacts.people.whose({ name: { _contains: nameOrEmail } })
                if (results.length === 0) return ""
                const emails = results[0].emails()
                return emails.length > 0 ? emails[0].value() : ""
            }
            """,
            aiCapability: "Opens Mail with the selected Finder file attached and recipient pre-filled. Resolves names to email from Contacts. Use for: 'share this with X via email', 'email this file to Gokula', 'send this document to X'.",
            tags: ["share", "email", "file", "attach", "finder", "send"]
        ),

        .init(
            appKey: "finder",
            name: "move-to-folder",
            displayName: "Move Selected File to Folder",
            language: .jxa,
            icon: "folder.badge.plus",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // move-to-folder — ILauncher Finder tool
            // argv[0] = source file path
            // argv[1] = destination folder path

            function run(argv) {
                const src  = (argv[0] || "").trim()
                const dest = (argv[1] || "").trim().replace(/^~/, app.pathTo("home folder").toString())
                if (!src || !dest) return "Error: source and destination required"

                const app    = Application("Finder")
                const srcItem  = app.items.byName(src)
                const destFolder = app.items.byName(dest)
                app.move(srcItem, { to: Path(dest) })
                return "Moved: " + src.split("/").pop() + " → " + dest
            }
            """,
            aiCapability: "Moves a file to a specified folder using Finder. Use for: 'move this to Downloads', 'organize this file into Documents', 'move selected file to X'.",
            tags: ["move", "file", "finder", "organize", "folder"]
        )
    ]

    // MARK: Safari

    static let safari: [AppleScriptTemplate] = [
        .init(
            appKey: "safari",
            name: "save-page-to-notes",
            displayName: "Save Current Page to Notes",
            language: .jxa,
            icon: "note.text.badge.plus",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // save-page-to-notes — ILauncher Safari + Notes tool
            // Saves the current Safari page URL + title to Notes

            function run(argv) {
                const summary = (argv[0] || "").trim() // optional user-provided summary

                const safari  = Application("Safari")
                const tab     = safari.windows[0].currentTab()
                const url     = tab.url()
                const title   = tab.name()

                const body = title + "\\n" + url + (summary ? "\\n\\n" + summary : "")
                const notes = Application("Notes")
                try { notes.folders.byName("Web Saves").name() }
                catch(_) { notes.make({ new: "folder", withProperties: { name: "Web Saves" } }) }

                notes.make({
                    new: "note",
                    at: notes.folders.byName("Web Saves"),
                    withProperties: { name: title, body: body }
                })
                return "Saved to Notes: " + title
            }
            """,
            aiCapability: "Saves the current Safari page (title + URL + optional summary) as a new note in Notes/Web Saves. Use for: 'save this page to notes', 'bookmark this in notes', 'save current link to notes with summary'.",
            tags: ["safari", "save", "notes", "url", "link", "bookmark"]
        )
    ]

    // MARK: Music

    static let music: [AppleScriptTemplate] = [
        .init(
            appKey: "music",
            name: "play-song",
            displayName: "Search and Play Song",
            language: .applescript,
            icon: "music.note",
            code: """
            -- play-song — ILauncher Music tool
            -- item 1 of argv = song name or artist to search and play

            on run argv
                set searchQuery to item 1 of argv
                tell application "Music"
                    set results to (every track of playlist "Library" whose name contains searchQuery or artist contains searchQuery)
                    if (count of results) > 0 then
                        play item 1 of results
                        set t to item 1 of results
                        return "Now playing: " & (name of t) & " by " & (artist of t)
                    else
                        return "No track found for: " & searchQuery
                    end if
                end tell
            end run
            """,
            aiCapability: "Searches the Music library for a song or artist and plays it. Use for: 'play X', 'play songs by Y', 'play Z by artist W'.",
            tags: ["play", "music", "song", "artist", "search"]
        )
    ]

    // MARK: FaceTime

    static let facetime: [AppleScriptTemplate] = [
        .init(
            appKey: "facetime",
            name: "facetime-call",
            displayName: "FaceTime Call",
            language: .jxa,
            icon: "video.fill",
            code: """
            #!/usr/bin/env osascript -l JavaScript
            // facetime-call — ILauncher FaceTime tool
            // argv[0] = contact name, phone, or email

            function run(argv) {
                const input = (argv[0] || "").trim()
                if (!input) return "Error: recipient required"

                const handle = resolveContact(input)
                if (!handle) return "Error: could not find contact: " + input

                // Open FaceTime with the handle
                const app = Application.currentApplication()
                app.includeStandardAdditions = true
                app.doShellScript("open 'facetime://" + encodeURIComponent(handle) + "'")
                return "Starting FaceTime with " + input + " (" + handle + ")"
            }

            function resolveContact(nameOrHandle) {
                if (nameOrHandle.includes("@") || /^[\\+\\d\\s\\-\\(\\)]{7,}$/.test(nameOrHandle)) {
                    return nameOrHandle
                }
                const contacts = Application("Contacts")
                const results  = contacts.people.whose({
                    _or: [
                        { name: { _contains: nameOrHandle } },
                        { firstName: { _contains: nameOrHandle } },
                        { lastName:  { _contains: nameOrHandle } }
                    ]
                })
                if (results.length === 0) return null
                const p = results[0]
                if (p.phones().length > 0) return p.phones[0].value()
                if (p.emails().length > 0) return p.emails[0].value()
                return null
            }
            """,
            aiCapability: "Starts a FaceTime audio or video call with any contact. Resolves names from Contacts automatically. Use for: 'FaceTime X', 'call X on FaceTime', 'video call Gokula'.",
            tags: ["facetime", "call", "video", "contact"]
        )
    ]

    // MARK: - By app key

    static func templates(for appKey: String) -> [AppleScriptTemplate] {
        all.filter { $0.appKey == appKey.lowercased() }
    }

    static func all(matching query: String) -> [AppleScriptTemplate] {
        let q = query.lowercased()
        return all.filter { t in
            t.displayName.lowercased().contains(q) ||
            t.appKey.lowercased().contains(q) ||
            t.tags.contains(where: { $0.contains(q) })
        }
    }
}

// MARK: - Template Picker Sheet

struct AppleTemplatePickerSheet: View {
    let appKey: String
    var onSelect: (AppleScriptTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var templates: [AppleScriptTemplate] {
        let base = search.isEmpty
            ? AppleAppScriptTemplates.all
            : AppleAppScriptTemplates.all(matching: search)
        // Sort: matching appKey first
        return base.sorted { a, b in
            let aMatch = a.appKey == appKey.lowercased()
            let bMatch = b.appKey == appKey.lowercased()
            if aMatch != bMatch { return aMatch }
            return a.displayName < b.displayName
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Apple App Templates")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search templates…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(templates) { template in
                        Button(action: { onSelect(template); dismiss() }) {
                            HStack(spacing: 12) {
                                Image(systemName: template.icon)
                                    .frame(width: 32, height: 32)
                                    .background(appColor(template.appKey).opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(appColor(template.appKey))

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(template.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                        if template.appKey == appKey.lowercased() {
                                            Text("for \(template.appKey.capitalized)")
                                                .font(.system(size: 9, weight: .medium))
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(appColor(template.appKey).opacity(0.15), in: Capsule())
                                                .foregroundStyle(appColor(template.appKey))
                                        }
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Image(systemName: template.language.systemImage)
                                                .font(.system(size: 9))
                                            Text(template.language.rawValue)
                                                .font(.system(size: 9))
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    Text(template.aiCapability)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                        .onHover { hov in }

                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .frame(width: 560, height: 460)
    }

    private func appColor(_ key: String) -> Color {
        switch key.lowercased() {
        case "messages":  return .green
        case "mail":      return .blue
        case "notes":     return .yellow
        case "reminders": return .orange
        case "calendar":  return .red
        case "contacts":  return .indigo
        case "finder":    return Color(nsColor: .systemTeal)
        case "safari":    return .blue
        case "music":     return .pink
        case "facetime":  return .green
        default:          return .accentColor
        }
    }
}
