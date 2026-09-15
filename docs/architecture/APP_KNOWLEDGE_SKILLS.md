# App knowledge, and why menus stop being a way to learn

## The thing tonight proved

A Safari-scoped chat answered `hi hello` by opening `Edit ▸ Extension Actions` and leaving
it hanging. Six candidates were eliminated by reading before the call stack named it: the
page-read path drives Safari's menu bar to wake our Web Extension, and because the
extension was not enabled, it hunted for an item that does not exist — on every query.

The bug is fixed. The lesson is bigger than the bug:

> **A menu is a way to *do* something. It was never a way to *know* something.**

DoraX has been using the menu bar as both. Menu clicking is Computer Use: it takes the
screen, it needs authority, it needs approval, and it is visible to the user. Using it to
find out what an app *is* spends the most expensive primitive in the system on the cheapest
question.

## What DoraX should know about an app before it answers

Everything below is already on disk or one HTTP call away. None of it requires clicking.

| Source | What it gives | Cost |
|---|---|---|
| **Help menu titles** (already in `AppMenuCapabilityCache`) | The vendor's own statement of what the app does — "Documentation", "Show All Commands", "Ask @vscode", "Report Issue", "Keyboard Shortcuts Reference" | free, cached |
| **About / bundle metadata** | Version, build, bundle id, install path, minimum OS | free, already in `ContextResolver` (`filled[version, installed at]`) |
| **The app's website** | What the product actually is, current features, docs, social links | one fetch, cached per version |
| **Registered capabilities** | Actions, CLI tools, MCP servers, API connections, Shortcuts | free, already enumerated |

The Help menu is the underused one. It is a structured, vendor-authored index of the app's
own documentation, it is already in the cache, and reading it requires **no** interaction —
the titles are in the AX tree whether or not anybody opens the menu.

## The shape: one learned Skill per adapter

`AdapterSkill` already exists and already fits — per bundle id, instructions only, never
executes anything, versioned, user-editable, shown in Settings ▸ App Adapters ▸ Tools ▸
Skills. `ChatRoute.Kind.skill` already routes to it and already says what it is: *"it
steers the model rather than running anything."*

What is missing is only that today's skill is **seeded from a hardcoded template**
(`AdapterSkillSeeder`) rather than **learned from the app in front of us**.

```
AppKnowledgeSkill(bundleId)
  ├─ About        → name, version, install path
  ├─ Help index   → the app's own documentation headings, from the menu cache
  ├─ Website      → product summary + docs/social links, fetched once per version
  └─ Capabilities → what DoraX can actually do here: actions, CLI, MCP, API, Shortcuts
```

Written as one `AdapterSkill` named `<App> — what this app is`, `version` set to the app's
own version so it refreshes when the app updates and never again in between.

## Why this makes the model look intelligent

Tonight's failures were not the model being stupid. Every one of them was the model being
handed the wrong thing before it got to think:

- `find my bookmarks note` → the resolver matched **Find My** because it scans every app
  installed on disk, and ranks leftmost-first.
- `turn on dark mode` → answered with `Appearance current value: true`, because the executor
  could see inputs and never intent.
- `hi hello` → a menu opened, because a page read could not reach its extension.

A model given "here is VS Code, version 1.9x, here is what its own Help menu indexes, here
is what the product is, and here are the five actions, four CLI tools and one skill you
actually have" does not need to guess. **The intelligence budget goes to the user's
sentence, not to reconstructing what the app is from a menu tree.**

## Two rules this establishes

1. **Menus are an execution surface, never a discovery surface.** Nothing may open a menu to
   find something out. `AppMenuCapabilityCache` is read; menus are only ever *clicked* for
   an action the user asked for and authorised.
2. **The candidate set is what the user granted, not what is installed.** Adapters, added
   folders, selection, clipboard, quick notes, Global Commands, MCP servers. `Find My` was
   never a capability — it is a file in `/Applications`, and it should never have competed.
   The possessive-phrase guard added tonight is a safety net over the wrong universe; the
   real fix is to stop scanning `InstalledApplicationsCatalog` for intent.

## Order of work

**Step 1 — Help index into the skill.** Pure local, no network, no new permissions. Read the
Help menu subtree from the cache, plus About, and write/refresh one `AdapterSkill` per
adapter. Shippable alone, and it is the piece that immediately changes answer quality.

**Step 2 — auto-expand the app sheet.** The result sheet already renders
`5 actions · 1 skills · 4 cli tools · 20 menu commands`. Show it on scope activation so the
user sees what DoraX can do in this app before typing, rather than discovering it by being
surprised.

**Step 3 — website knowledge.** Fetch the product page once per app version, summarise into
the skill, keep docs and social links. Needs a cache, a size cap, and an explicit user
toggle: this is the only step that leaves the machine.

**Step 4 — capability-set intent matching.** Replace installed-app name scanning with
ranking over granted capabilities. This is the one that retires the possessive guard, and it
is the largest.

Steps 1 and 2 need no network and no new authority. Step 3 does. Step 4 is a resolver
change and wants its own tests before anything moves.
