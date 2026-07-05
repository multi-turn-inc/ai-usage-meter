import Foundation

public enum ServiceType: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    public var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex: return "terminal"
        case .gemini: return "sparkles"
        }
    }

    public var brandColorHex: String {
        switch self {
        case .claude: return "#D97706"
        case .codex: return "#6B7CF6"
        case .gemini: return "#4285F4"
        }
    }
}
