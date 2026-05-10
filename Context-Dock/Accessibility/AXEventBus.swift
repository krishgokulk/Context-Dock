import AppKit
import Combine

// MARK: - AXEvent — typed events flowing through the system

enum AXEvent {
    case appActivated(NSRunningApplication)
    case focusedElementChanged(pid_t)
    case selectedTextChanged(pid_t)
    case menuItemsReady(pid_t, [AXMenuItemInfo])
}

// MARK: - AXEventBus — central pub/sub hub

final class AXEventBus {
    static let shared = AXEventBus()

    private let subject = PassthroughSubject<AXEvent, Never>()

    var publisher: AnyPublisher<AXEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    private init() {}

    func emit(_ event: AXEvent) {
        subject.send(event)
    }
}
