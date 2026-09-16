// DoraXDiagnosticCapture.swift
// Context-Dock
//
// Keeps the last few failures, so the report can be asked for after the fact.
//
// A user notices something is wrong and reaches for Settings a minute later; by then the
// chat has moved on. Holding the last handful of captures means the report is still
// available when they go looking, without asking them to reproduce it first — reproducing
// is the part they cannot reliably do.
//
// In memory only. This is a record of what went wrong in this session, not a log file to
// grow on disk, and a failure worth keeping is one the user is about to send somewhere.

import Combine
import Foundation

@MainActor
final class DoraXDiagnosticCapture: ObservableObject {
    static let shared = DoraXDiagnosticCapture()

    @Published private(set) var recent: [DoraXDiagnosticReport] = []

    private let maxKept = 10

    private init() {}

    func record(symptom: String, query: String?, scope: GeneralChatScope?) {
        let report = DoraXDiagnosticReport(symptom: symptom, query: query, scope: scope)
        recent.append(report)
        if recent.count > maxKept { recent.removeFirst(recent.count - maxKept) }
    }

    var latest: DoraXDiagnosticReport? { recent.last }

    func clear() { recent = [] }
}
