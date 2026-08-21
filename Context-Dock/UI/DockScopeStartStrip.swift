// DockScopeStartStrip.swift
// Context-Dock
//
// What an app's dock thread shows before anyone types.
//
// Step 2 of docs/architecture/APP_KNOWLEDGE_SKILLS.md. The chat window already answers
// "this app, this assistant, what now" with AppScopedStartView. The dock — where people
// actually scope to the frontmost app — answered it with nothing: the header appeared and
// the space below it stayed empty until a message existed.
//
// Built from the same ScopeInventory the window and the side panel read, so the three can
// never disagree about what is in scope, and a suggestion can never name something that is
// not there.
//
// Unified Dock Surface rule: this is not a new floating container. It is rows inside the
// shell that is already open, using the dock's own spacing and type scale.

import SwiftUI

struct DockScopeStartStrip: View {
    let appName: String
    let bundleId: String
    /// Fills the composer. Deliberately does not send — the dock's Return is the user's,
    /// and a suggestion that runs itself is an action nobody approved.
    let onPick: (String) -> Void

    private var inventory: ScopeInventory {
        ScopeInventory.app(bundleId: bundleId, appName: appName)
    }

    var body: some View {
        let inventory = inventory
        VStack(alignment: .leading, spacing: 6) {
            Text(summary(inventory))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ForEach(starters(inventory), id: \.prompt) { starter in
                Button { onPick(starter.prompt) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: starter.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(starter.prompt)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    /// What is in scope, counted. "20 menu commands" is the fact that tells someone this
    /// thread can drive the app.
    private func summary(_ inventory: ScopeInventory) -> String {
        let counts = inventory.groups.map { "\($0.items.count) \($0.title.lowercased())" }
        return counts.isEmpty
            ? "Nothing is linked to \(appName) yet."
            : counts.prefix(4).joined(separator: " · ")
    }

    /// One opener per group, named after something that actually exists in scope. Three at
    /// most: the dock is a strip, not a menu.
    private func starters(_ inventory: ScopeInventory) -> [(prompt: String, symbol: String)] {
        inventory.groups.prefix(3).compactMap { group in
            guard let first = group.items.first else { return nil }
            // Inventory items can carry a qualifier ("Empty Trash — asks first"); the
            // opener should read as the thing itself.
            let name = first.components(separatedBy: " — ").first ?? first
            return (name, group.symbol)
        }
    }
}
