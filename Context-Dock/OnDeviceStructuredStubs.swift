// OnDeviceStructuredStubs.swift
// Context-Dock
//
// Minimal stubs for on-device structured output types that were removed
// with OnDeviceStructuredOutput.swift. These allow the call sites to compile;
// the real @Generable implementations have been replaced with nil returns.

#if canImport(FoundationModels)
import Foundation

@available(macOS 26.0, *)
struct GeneratedMailIntent {
    var mode: String
    var searchQuery: String
    var tokenKind: String
}

@available(macOS 26.0, *)
func generateMailIntent(
    from query: String,
    dateTimeContext: String
) async throws -> GeneratedMailIntent? {
    return nil
}
#endif
