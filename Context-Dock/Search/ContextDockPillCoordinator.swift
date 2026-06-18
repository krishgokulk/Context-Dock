import Foundation

@MainActor
struct ContextDockPillCoordinator {
    struct Input {
        let query: String
        let lastQuery: String
        let delayNanoseconds: UInt64
        let refreshContext: Bool
        let cachedPills: [DockPill]
        let previewPills: [DockPill]
        let isQuestionStyle: Bool
    }

    struct Actions {
        let commitPreview: ([DockPill]) -> Void
        let clearCachedPills: () -> Void
        let refreshContext: () -> Void
        let buildPills: (String) -> [DockPill]
        let replaceCachedPills: ([DockPill], Bool) -> Void
        let logPerformance: (Date, String) -> Void
    }

    static func schedule(
        input: Input,
        viewModel: ContextDockViewModel,
        actions: Actions
    ) -> Task<Void, Never>? {
        let isDeletion = input.lastQuery.hasPrefix(input.query)
            && input.query.count < input.lastQuery.count

        let scheduleStart = viewModel.preparePillRebuild(
            query: input.query,
            isDeletion: isDeletion,
            isQuestionStyle: input.isQuestionStyle,
            cachedPills: input.cachedPills,
            previewPills: input.previewPills
        )

        let scheduledGeneration: Int
        switch scheduleStart {
        case .skipped:
            return nil
        case .duplicate(let previewPills):
            actions.commitPreview(previewPills)
            return nil
        case .questionStyle:
            actions.clearCachedPills()
            return nil
        case .scheduled(let generation, let previewPills):
            scheduledGeneration = generation
            actions.commitPreview(previewPills)
        }

        return Task { @MainActor in
            try? await Task.sleep(nanoseconds: input.delayNanoseconds)
            guard !Task.isCancelled,
                viewModel.scheduledPillRebuildCanContinue(
                    generation: scheduledGeneration,
                    query: input.query
                )
            else { return }

            let shouldRefresh = input.refreshContext && input.query.isEmpty
            if shouldRefresh {
                actions.refreshContext()
                guard !Task.isCancelled,
                    viewModel.scheduledPillRebuildCanContinue(
                        generation: scheduledGeneration,
                        query: input.query
                    )
                else { return }
            }

            guard viewModel.scheduledPillRebuildCanContinue(
                generation: scheduledGeneration,
                query: input.query
            ) else { return }

            await Task.yield()
            guard !Task.isCancelled,
                viewModel.scheduledPillRebuildCanContinue(
                    generation: scheduledGeneration,
                    query: input.query
                )
            else { return }

            let started = Date()
            actions.replaceCachedPills(actions.buildPills(input.query), true)
            actions.logPerformance(started, input.query)
            viewModel.finishScheduledPillRebuild(query: input.query)
        }
    }
}
