import Combine

@MainActor
final class CornerDockKeyboardState: ObservableObject {
    @Published private(set) var isArmed = false
    @Published private(set) var focusRequestToken = 0

    func composerInteracted() {
        isArmed = true
        focusRequestToken &+= 1
    }

    func stoodDown() {
        isArmed = false
    }
}
