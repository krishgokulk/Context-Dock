import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

struct KeyboardHintBadge: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}



// MARK: - Contact Quick Action Button
// ContactQuickActionButton moved to ResultRow.swift

// MARK: - Resize Handle Component
struct ResizeHandle: View {
    @Binding var isDragging: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(isHovering || isDragging ? 0.2 : 0.1), radius: 4)

            // Resize icon (diagonal arrows)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering || isDragging ? .primary : .secondary)
                .rotationEffect(.degrees(90))
        }
        .padding(12)
        .opacity(isDragging ? 1.0 : (isHovering ? 0.9 : 0.6))
        .scaleEffect(isDragging ? 1.15 : (isHovering ? 1.05 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .help("Drag to resize • 75% of screen by default")
    }
}

// MARK: - Folder Item Row
// MARK: - AI Chat Models
/// Spotlight-style context: set when user presses Tab/→ on any search result
