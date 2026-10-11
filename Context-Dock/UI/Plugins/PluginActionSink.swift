// Context-Dock
//
// How a component asks for something to happen. Phase 2 draws; Phase 3 runs. The renderer
// therefore never calls a runner — it hands a request to whatever sink the host installed, and
// in tests and previews that sink only records.

import Foundation

struct PluginActionRequest: Equatable {
    let name: String
    let value: PluginValue?

    init(name: String, value: PluginValue? = nil) {
        self.name = name
        self.value = value
    }
}

@MainActor
protocol PluginActionSink: AnyObject {
    func run(_ request: PluginActionRequest)
}

/// The sink tests and previews use: it remembers what was asked for and does nothing.
@MainActor
final class RecordingActionSink: PluginActionSink {
    private(set) var requests: [PluginActionRequest] = []
    func run(_ request: PluginActionRequest) { requests.append(request) }
}
