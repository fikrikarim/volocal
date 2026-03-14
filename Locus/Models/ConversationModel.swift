import Foundation

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()

    enum Role {
        case user
        case assistant
    }
}
