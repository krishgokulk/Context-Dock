import SwiftUI

/// Measures local search retrieval quality (Hit@5 / MRR). A developer/QA tool — moved out of
/// Data & Storage (user settings) into Advanced, beside the search index it exercises
/// (owner 2026-11-07).
struct RetrievalEvaluationCard: View {
    @StateObject private var retrievalEvaluation = RetrievalEvaluationStore.shared
    @State private var retrievalQuery = ""
    @State private var expectedRetrievalText = ""

    var body: some View {
        CardSection(title: "Retrieval Evaluation", systemImage: "scope") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Measure the existing local retrieval before considering GraphRAG. Enter a query and a piece of text that should appear in the results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Query, for example: Context-Dock", text: $retrievalQuery)
                    .textFieldStyle(.roundedBorder)
                TextField("Expected app, menu, file, or URL text", text: $expectedRetrievalText)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Run Evaluation") {
                        _ = retrievalEvaluation.run(
                            query: retrievalQuery,
                            expectedText: expectedRetrievalText)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || expectedRetrievalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !retrievalEvaluation.results.isEmpty {
                        Text("Hit@5 \(retrievalEvaluation.hitRateAt5, format: .percent.precision(.fractionLength(0)))  ·  MRR \(retrievalEvaluation.meanReciprocalRank, format: .number.precision(.fractionLength(2)))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Results", role: .destructive) {
                            retrievalEvaluation.clear()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let result = retrievalEvaluation.results.first {
                    Divider()
                    RetrievalEvaluationResultRow(result: result)
                }
            }
            .padding(.vertical, 12)
        }
    }
}

private struct RetrievalEvaluationResultRow: View {
    let result: RetrievalEvaluationResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.hitAt5 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.hitAt5 ? .green : .red)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.hitAt5 ? "Pass · hit at rank \(result.rank ?? 0)" : "Miss · expected text not in top 5")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(result.resultCount) rows · \(result.latencyMilliseconds, format: .number.precision(.fractionLength(1))) ms")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let row = result.matchedRow {
                    Text(row)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }
}
