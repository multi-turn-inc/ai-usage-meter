import AppKit
import SwiftUI

struct BugReportPanel: View {
    @Binding var isPresented: Bool
    @State private var reportText: String = ""
    @State private var includeDiagnostics: Bool = true
    @State private var showDiagnosticPreview: Bool = false
    @State private var isSending = false
    @State private var sent = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Text(L.bugReport)
                    .font(.system(size: 16, weight: .bold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if sent {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text(L.bugReportSent)
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .transition(.scale.combined(with: .opacity))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        TextEditor(text: $reportText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(nsColor: .separatorColor).opacity(0.3))
                                    )
                            )
                            .frame(minHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if reportText.isEmpty {
                                    Text(L.bugReportPlaceholder)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 18)
                                        .allowsHitTesting(false)
                                }
                            }

                        // Diagnostics toggle
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "stethoscope")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(L.includeDiagnostics)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Toggle("", isOn: $includeDiagnostics)
                                    .toggleStyle(.switch)
                                    .tint(.accentColor)
                                    .labelsHidden()
                                    .scaleEffect(0.7)
                                    .frame(width: 36, height: 20)
                            }

                            if includeDiagnostics {
                                Button {
                                    showDiagnosticPreview.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(L.viewDiagnostics)
                                            .font(.system(size: 11))
                                        Image(systemName: showDiagnosticPreview ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)

                                if showDiagnosticPreview {
                                    Text(DiagnosticCollector.collect())
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.2))
                                        )
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.2))
                                )
                        )
                        .animation(.easeInOut(duration: 0.2), value: includeDiagnostics)
                        .animation(.easeInOut(duration: 0.2), value: showDiagnosticPreview)

                        HStack {
                            Spacer()
                            Button {
                                sendReport()
                            } label: {
                                HStack(spacing: 6) {
                                    if isSending {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 12))
                                    }
                                    Text(L.send)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .disabled(reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sent)
    }

    private func sendReport() {
        let text = reportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true

        // Escape user- and shell-derived content before splicing into HTML — the
        // report goes through Resend as `text/html`, and neither the free-form
        // user text nor the diagnostics (which include shell output) can be
        // trusted to be markup-safe.
        let diagnostics = includeDiagnostics ? DiagnosticCollector.collect() : nil
        let escapedText = DiagnosticCollector.htmlEscape(text)
            .replacingOccurrences(of: "\n", with: "<br>")
        var htmlBody = "<h3>Bug Report</h3><p>\(escapedText)</p>"
        if let diag = diagnostics {
            htmlBody += "<h4>Diagnostics</h4><pre>\(DiagnosticCollector.htmlEscape(diag))</pre>"
        }

        let payload: [String: Any] = [
            "from": "Token Burn <onboarding@resend.dev>",
            "to": [FeedbackConfig.feedbackEmail],
            "subject": "Bug Report — Token Burn",
            "html": htmlBody
        ]

        guard let url = URL(string: "https://api.resend.com/emails"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            isSending = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(FeedbackConfig.resendAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                isSending = false
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isPresented = false
                    }
                }
            }
        }.resume()
    }
}
