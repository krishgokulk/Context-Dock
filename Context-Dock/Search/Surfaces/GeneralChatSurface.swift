import SwiftUI

struct GeneralChatSurface: View {
    @EnvironmentObject var appState: AppState
    @State var messages: [AIChatMessage] = []
    @State var inputText: String = ""
    @State var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages, id: \.id) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(8)
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)

            Divider()

            // Input
            HStack(spacing: 8) {
                TextField("Ask anything...", text: $inputText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        let userMessage = AIChatMessage(role: .user, content: inputText)
        messages.append(userMessage)
        inputText = ""
        isLoading = true

        Task {
            // Placeholder: integrate with actual AIProviderService
            await MainActor.run {
                let aiMessage = AIChatMessage(role: .assistant, content: "AI response would go here")
                messages.append(aiMessage)
                isLoading = false
            }
        }
    }
}

struct ChatMessageBubble: View {
    let message: AIChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading) {
                Text(message.content)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(message.role == .user
                        ? Color.accentColor
                        : Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
            }

            if message.role == .assistant {
                Spacer()
            }
        }
    }
}
