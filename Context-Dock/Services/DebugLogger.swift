// DebugLogger.swift
// Context-Dock
//
// Shadows Swift.print so all existing print() calls compile away in Release builds.
// No changes required elsewhere — this module-level override takes precedence
// over the standard library within this target.

@inline(__always)
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
#endif
}
