import Combine
import Foundation

enum AppRoute: Equatable {
    case contextDock
    case globalContext
    case mediaDock
    case aiChat
    case settings
}

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published private(set) var route: AppRoute = .contextDock

    private init() {}

    func navigate(to route: AppRoute) {
        self.route = route
    }
}
