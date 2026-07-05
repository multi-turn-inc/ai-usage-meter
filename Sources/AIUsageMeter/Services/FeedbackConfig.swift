import Foundation

enum FeedbackConfig {
    static var resendAPIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "ResendAPIKey") as? String ?? ""
    }
    static var feedbackEmail: String {
        Bundle.main.object(forInfoDictionaryKey: "FeedbackEmail") as? String ?? ""
    }
    static var donationURL: String {
        Bundle.main.object(forInfoDictionaryKey: "DonationURL") as? String ?? ""
    }
}
