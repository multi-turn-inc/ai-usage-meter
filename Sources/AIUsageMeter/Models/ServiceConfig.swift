import Foundation
import SwiftUI

struct ServiceConfig: Codable, Identifiable {
    let id: UUID
    var serviceType: ServiceType
    var apiKey: String
    var organizationId: String?
    var isEnabled: Bool
    var refreshInterval: TimeInterval
    var notificationThreshold: Double

    init(
        id: UUID = UUID(),
        serviceType: ServiceType,
        apiKey: String = "",
        organizationId: String? = nil,
        isEnabled: Bool = true,
        refreshInterval: TimeInterval = 300,
        notificationThreshold: Double = 80
    ) {
        self.id = id
        self.serviceType = serviceType
        self.apiKey = apiKey
        self.organizationId = organizationId
        self.isEnabled = isEnabled
        self.refreshInterval = refreshInterval
        self.notificationThreshold = notificationThreshold
    }

    var iconName: String { serviceType.iconName }
    var displayName: String { serviceType.displayName }

    var brandColor: Color {
        Color(hex: serviceType.brandColorHex) ?? .blue
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
