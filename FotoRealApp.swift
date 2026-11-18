import SwiftUI

/// Endereço do site do FOTO REAL. O app abre este endereço por dentro.
/// Se o seu site tiver outro endereço, troque aqui ou digite no app na tela de "sem conexão".
enum AppConfig {
    static let defaultSite = "https://fotoreal.pages.dev"

    static var siteURL: URL {
        let saved = UserDefaults.standard.string(forKey: "siteURL") ?? ""
        return URL(string: saved.isEmpty ? defaultSite : saved) ?? URL(string: defaultSite)!
    }

    static func saveSite(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.lowercased().hasPrefix("http") { t = "https://" + t }
        UserDefaults.standard.set(t, forKey: "siteURL")
    }
}

@main
struct FotoRealApp: App {
    var body: some Scene {
        WindowGroup {
            WebContainer()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}

struct WebContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
