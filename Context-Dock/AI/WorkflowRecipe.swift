// WorkflowRecipe.swift
// Context-Dock
//
// A plan the user can name, keep, and run again.
//
// A ChatPlan is resolved for one question and thrown away. That is right for "find the PDF
// and email it to Sarah", and wrong for the sequence someone runs thirty times a day —
// build, launch, reproduce, capture — where re-typing the request is the coordination
// overhead the plan was supposed to remove.
//
// The obvious implementation is to serialise the plan. It does not work. A ChatRoute's id
// is minted during discovery for one query — "cli:swift build", an adapter action id, a
// menu path — so ids saved today bind next week to a different command, or to nothing,
// and the user finds out by watching it run.
//
// So a recipe stores what each step *was* — its kind, its app, its title, and the payload
// that would run — and resolves routes again at run time, binding each step only to a live
// route that still matches. A step whose capability is gone stops the run and says which
// one, rather than substituting the nearest thing it can find. That is the same rule the
// rest of this code already follows: a plan may only contain capabilities that resolved as
// real, and nothing gets clicked without live verification.

import Combine
import Foundation
import OSLog

// MARK: - Model

/// One saved step. Deliberately not a `ChatRoute`: it describes a capability well enough to
/// find it again, and holds no id that pretends to survive the session it was made in.
struct WorkflowRecipeStep: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Why this step is in the recipe, in the user's terms. Shown while it runs.
    var purpose: String
    /// `ChatRoute.Kind.rawValue`. Stored as a string so an unknown kind from a newer build
    /// decodes instead of taking the whole file down.
    var kind: String
    var bundleId: String
    var appName: String
    /// What the capability was called when it was saved.
    var title: String
    /// The command, action id, or menu path that ran. The primary key when re-binding: a
    /// title can be reworded between app versions, what actually executes usually is not.
    var payload: String
    var isReadOnly: Bool

    init(purpose: String, route: ChatRoute) {
        self.purpose = purpose
        self.kind = route.kind.rawValue
        self.bundleId = route.bundleId
        self.appName = route.appName
        self.title = route.title
        self.payload = route.payload
        self.isReadOnly = route.isReadOnly
    }
}

struct WorkflowRecipe: Codable, Equatable, Identifiable {
    var id = UUID()
    /// What the user calls it — "Test DoraX". This is the handle they will type.
    var name: String
    /// The request this was recorded from. Kept because re-resolution needs query terms to
    /// search against, and because it is the honest record of what the recipe means.
    var query: String
    var steps: [WorkflowRecipeStep]
    var createdAt: Date = Date()
    var lastRunAt: Date?

    /// Recorded from a plan that already ran. Recording only after a successful run is the
    /// point — a recipe is a sequence known to work, not one the model once proposed.
    init(name: String, query: String, plan: ChatPlan) {
        self.name = name
        self.query = query
        self.steps = plan.steps.map {
            WorkflowRecipeStep(purpose: $0.purpose, route: $0.route)
        }
    }
}

// MARK: - Store

/// Recipes on disk, under the same Application Support root as the rest of the app's
/// file-based config.
@MainActor
final class WorkflowRecipeStore: ObservableObject {
    static let shared = WorkflowRecipeStore()

    @Published private(set) var recipes: [WorkflowRecipe] = []

    private let fileURL: URL
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "WorkflowRecipe")

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("workflows.json")
        load()
    }

    /// Saves under `name`, replacing any recipe already using it. Names are how the user
    /// refers to these, so two recipes called "Test DoraX" would make the reference
    /// ambiguous at exactly the moment it matters.
    func save(_ recipe: WorkflowRecipe) {
        recipes.removeAll { $0.name.caseInsensitiveCompare(recipe.name) == .orderedSame }
        recipes.insert(recipe, at: 0)
        persist()
    }

    func delete(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        persist()
    }

    func named(_ name: String) -> WorkflowRecipe? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return recipes.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    func markRun(_ id: UUID) {
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes[index].lastRunAt = Date()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([WorkflowRecipe].self, from: data)
        else { return }
        recipes = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Running

@MainActor
enum WorkflowRecipeRunner {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "WorkflowRecipe")

    enum Binding {
        /// Every step found a live route. Safe to run.
        case ready(ChatPlan)
        /// A step's capability no longer resolves. Carries what was there instead, so the
        /// user can see whether the app changed or the recipe was always fragile.
        case missing(step: WorkflowRecipeStep, found: [String])
    }

    /// Resolves each saved step against what the machine can currently do.
    ///
    /// Matching is payload first, title second, and both are scoped to the step's own kind
    /// and app. Nothing looser: a near-miss here would run a different command than the one
    /// the user recorded, under a name that says otherwise.
    static func bind(_ recipe: WorkflowRecipe) async -> Binding {
        var steps: [ChatPlanStep] = []

        for step in recipe.steps {
            // Resolution searches by query terms, so the step's own title is the most
            // reliable thing to search with — it is the capability's name. The original
            // request is appended to widen recall; the exact match below is what keeps
            // that widening safe.
            let live = await ChatRouteResolver.routes(
                for: "\(step.title) \(recipe.query)",
                bundleId: step.bundleId,
                appName: step.appName)
            let sameKind = live.filter { $0.kind.rawValue == step.kind }

            let match =
                sameKind.first { $0.payload == step.payload }
                ?? sameKind.first { $0.title.caseInsensitiveCompare(step.title) == .orderedSame }

            guard let match else {
                log.notice(
                    "recipe \(recipe.name, privacy: .public): step \(step.title, privacy: .public) no longer resolves")
                return .missing(step: step, found: sameKind.map(\.title))
            }
            steps.append(ChatPlanStep(route: match, purpose: step.purpose))
        }

        return .ready(ChatPlan(steps: steps, summary: recipe.name))
    }

    /// Binds, then runs through the ordinary plan machinery — approval gates, console log
    /// and post-step verification all behave exactly as they do for a plan the model just
    /// built. A saved recipe is not a shortcut past consent.
    static func run(_ recipe: WorkflowRecipe) async -> (text: String, chips: [String]) {
        switch await bind(recipe) {
        case .missing(let step, let found):
            let alternatives = found.isEmpty
                ? "Nothing of that kind is available in \(step.appName) right now."
                : "\(step.appName) currently offers: " + found.prefix(5).joined(separator: ", ")
            return (
                """
                Didn't run “\(recipe.name)”. Step \(stepNumber(of: step, in: recipe)) — \
                \(step.purpose) — used `\(step.title)` in \(step.appName), and that is no \
                longer there.

                \(alternatives)

                Record the workflow again to pick up what replaced it.
                """,
                []
            )

        case .ready(let plan):
            let results = await ChatPlanRunner.run(plan, query: recipe.query)
            WorkflowRecipeStore.shared.markRun(recipe.id)
            let receipt = ChatPlanRunner.receipt(plan, results: results)
            let allSucceeded =
                results.allSatisfy(\.success) && results.count == plan.steps.count
            return (
                (allSucceeded ? "\(recipe.name)\n\n" : "")
                    + receipt
                    + (allSucceeded ? "" : "\n\nNothing after the failed step was attempted."),
                results.map { "\($0.step.route.kind.rawValue) · \($0.step.route.title)" }
            )
        }
    }

    private static func stepNumber(of step: WorkflowRecipeStep, in recipe: WorkflowRecipe)
        -> Int
    {
        (recipe.steps.firstIndex(of: step) ?? 0) + 1
    }
}
