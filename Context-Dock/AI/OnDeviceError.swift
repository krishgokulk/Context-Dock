import Foundation

/// Typed errors from the on-device (Apple Intelligence) AI path.
///
/// Error descriptions are phrased so `DockCore+AIChat.swift`'s `QueryFailureKind`
/// classifier can map them without string-matching raw Apple error messages:
///  - `.contextWindowOverflow` contains "context" → `.onDeviceContextOverflow`
///  - `.notAvailable`         contains "apple silicon" → `.onDeviceNotAvailable`
///  - `.generationFailed`     falls through to `.onDeviceGeneralError`
enum OnDeviceError: Error, LocalizedError {
    case notAvailable(String)
    case contextWindowOverflow
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let reason):
            return "Apple Intelligence requires Apple Silicon and macOS 26.0 or later. \(reason)"
        case .contextWindowOverflow:
            return "On-device context window overflow: the conversation history exceeds the model's token limit. Condensed history and retried but the context is still too long."
        case .generationFailed(let reason):
            return "Apple Intelligence generation failed: \(reason)"
        }
    }
}
