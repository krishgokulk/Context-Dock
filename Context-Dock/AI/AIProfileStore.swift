import Foundation
import Combine

@MainActor
final class AIProfileStore: ObservableObject {
    static let shared = AIProfileStore()

    @Published private(set) var profiles: [AIProfile] = []

    private let defaultsKey = "aiProfilesData_v1"

    private init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([AIProfile].self, from: data),
              !decoded.isEmpty else {
            profiles = AIProfile.defaults
            save()
            return
        }
        profiles = decoded.sorted { $0.priority > $1.priority }
    }

    func save() {
        let sorted = profiles.sorted { $0.priority > $1.priority }
        profiles = sorted
        if let data = try? JSONEncoder().encode(sorted) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "ai-profiles")
    }

    func replaceProfiles(_ newProfiles: [AIProfile]) {
        profiles = newProfiles.sorted { $0.priority > $1.priority }
        save()
    }

    func resetToDefaults() {
        profiles = AIProfile.defaults
        save()
    }

    func profile(for request: AIRequest) -> AIProfile {
        let text = request.text.lowercased()
        let bundleId = request.frontmostBundleId?.lowercased()

        let enabled = profiles.filter(\.enabled).sorted { $0.priority > $1.priority }

        if let bundleId {
            if let exact = enabled.first(where: { profile in
                profile.appBundleIds.contains { $0.lowercased() == bundleId }
            }) {
                return exact
            }
        }

        if let keyword = enabled.first(where: { profile in
            !profile.triggerKeywords.isEmpty &&
            profile.triggerKeywords.contains { text.contains($0.lowercased()) }
        }) {
            return keyword
        }

        return enabled.first(where: { $0.name == AIProfile.general.name }) ?? .general
    }
}

extension AIRequest {
    var frontmostBundleId: String? {
        if let live = liveContext, !live.bundleIdentifier.isEmpty { return live.bundleIdentifier }
        if case .appFocused(_, let bundleID) = context { return bundleID }
        return nil
    }

    var frontmostAppName: String? {
        if let live = liveContext, !live.frontmostApp.isEmpty { return live.frontmostApp }
        if case .appFocused(let name, _) = context { return name }
        return nil
    }
}
