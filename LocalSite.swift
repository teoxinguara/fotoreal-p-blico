import Foundation
import WebKit

/// O FOTO REAL guardado dentro do app: abre sem internet.
/// Com internet, baixa sozinho a versão mais nova do seu site e usa na próxima abertura.
enum LocalSite {
    static let start = URL(string: "fotoreal://app/index.html")!

    /// Cópia que veio dentro do app (arquivo FotoRealSite.html).
    static var bundled: URL? { Bundle.main.url(forResource: "FotoRealSite", withExtension: "html") }

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("site", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Cópia baixada do site (atualização).
    static var cached: URL { cacheDir.appendingPathComponent("index.html") }

    /// Pasta onde as fotos da câmera esperam o app web buscar.
    static var inbox: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var available: Bool { bundled != nil || FileManager.default.fileExists(atPath: cached.path) }

    static func clearInbox() {
        let dir = inbox
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func version(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "APP_VER='[0-9.]+'", options: .regularExpression) else { return nil }
        return text[r].replacingOccurrences(of: "APP_VER='", with: "").replacingOccurrences(of: "'", with: "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// A página mais nova entre a que veio no app e a que foi baixada do site.
    static func currentPage() -> Data? {
        let inApp = bundled.flatMap { try? Data(contentsOf: $0) }
        guard let down = try? Data(contentsOf: cached), let dv = version(of: down) else { return inApp }
        guard let mine = inApp, let mv = version(of: mine) else { return down }
        return isNewer(dv, than: mv) ? down : mine
    }

    static func currentVersion() -> String { currentPage().flatMap { version(of: $0) } ?? "?" }

    /// Procura uma versão mais nova no site. Responde (versão nova, mensagem).
    static func checkUpdate(site: URL, done: @escaping (String?, String) -> Void) {
        var parts = URLComponents(url: site.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "v", value: String(Int(Date().timeIntervalSince1970)))]
        guard let url = parts?.url else { done(nil, "Endereço do site inválido"); return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, response, error in
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 50_000, let v = version(of: data) else {
                done(nil, error == nil ? "Não encontrei o FOTO REAL no endereço do site" : "Sem internet agora")
                return
            }
            let now = currentVersion()
            guard isNewer(v, than: now) else { done(nil, "Você já está na versão mais nova (\(now))"); return }
            do {
                try data.write(to: cached, options: .atomic)
                done(v, "")
            } catch {
                done(nil, "Não consegui guardar a atualização")
            }
        }.resume()
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json", "webmanifest": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

/// Entrega as páginas e as fotos para o app web quando ele pede fotoreal://app/...
final class SiteSchemeHandler: NSObject, WKURLSchemeHandler {
    private var active = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        active.insert(key)
        guard let url = task.request.url else { return }
        let path = url.path.isEmpty ? "/" : url.path
        DispatchQueue.global(qos: .userInitiated).async {
            var data: Data?
            var type = "application/octet-stream"
            if path == "/" || path == "/index.html" {
                data = LocalSite.currentPage()
                type = LocalSite.mime("html")
            } else if path.hasPrefix("/_in/") {
                let id = String(path.dropFirst(5))
                if !id.isEmpty, !id.contains("/"), !id.contains("..") {
                    data = try? Data(contentsOf: LocalSite.inbox.appendingPathComponent(id), options: .mappedIfSafe)
                }
            } else {
                let name = (path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension
                if let file = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: ext) {
                    data = try? Data(contentsOf: file)
                }
                type = LocalSite.mime(ext)
            }
            Task { @MainActor in
                guard self.active.remove(key) != nil else { return }
                let code = data == nil ? 404 : 200
                let body = data ?? Data()
                let headers = ["Content-Type": data == nil ? "text/plain" : type,
                               "Content-Length": String(body.count),
                               "Cache-Control": "no-store"]
                if let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) {
                    task.didReceive(response)
                }
                if !body.isEmpty { task.didReceive(body) }
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }
}
