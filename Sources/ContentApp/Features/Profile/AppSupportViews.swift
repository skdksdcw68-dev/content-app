import SwiftUI
import SafariServices

/// Light, dark, or the iPhone's own setting.
struct AppearanceView: View {
    @State private var appearance = AppAppearance.current

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: appearance) { _, value in AppAppearance.current = value }
            } footer: {
                Text("Light is Autocast’s look. System follows your iPhone.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A web page inside the app, with Safari's own controls.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Where Autocast's own pages live.
enum AutocastLinks {
    static let privacy = URL(string: "https://netrocast.com/privacy")!
    static let terms = URL(string: "https://netrocast.com/terms")!
    static let supportEmail = "hello@netrocast.com"

    static var supportMail: URL {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = supportEmail
        parts.queryItems = [
            URLQueryItem(name: "subject", value: "Autocast \(version) (\(build))"),
        ]
        return parts.url ?? URL(string: "mailto:\(supportEmail)")!
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Autocast \(version) (\(build))"
    }
}

/// The exported ZIP, handed to the share sheet as a file.
struct ExportShare: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet, for a file that only exists once it has been made.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
