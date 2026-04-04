import Foundation
import SwiftUI

enum ServiceType: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex: return "terminal"
        case .gemini: return "sparkles"
        }
    }

    var brandColorHex: String {
        switch self {
        case .claude: return "#D97706"
        case .codex: return "#10A37F"
        case .gemini: return "#4285F4"
        }
    }

    var brandColor: Color {
        Color(hex: brandColorHex) ?? .blue
    }
}
