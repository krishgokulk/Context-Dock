import SwiftUI

struct ContextDockChatSurface: View {
    @State var messages: [AIChatMessage] = []
    @State var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages, id: \.id) { message in
                        ChatMessageBubble(message: message)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 250)

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about context...", text: $inputText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                Button(action: { sendMessage() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func sendMessage() {
        let msg = AIChatMessage(role: .user, content: inputText)
        messages.append(msg)
        inputText = ""
    }
}
