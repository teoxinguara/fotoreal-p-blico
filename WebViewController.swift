import UIKit
import WebKit

/// Tela única do app: mostra o FOTO REAL (o mesmo do site) e liga a câmera do cabo a ele.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private var web: WKWebView!
    private let camera = CameraBridge()
    private var downloadTargets: [ObjectIdentifier: URL] = [:]
    private var pendingShares: [URL] = []
    private var sharing = false
    private var saves: [String: FileHandle] = [:]
    private let ground = UIColor(red: 14 / 255, green: 14 / 255, blue: 16 / 255, alpha: 1)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ground

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let content = WKUserContentController()
        content.add(WeakMessageHandler(self), name: "fotoreal")
        content.addUserScript(WKUserScript(source: "window.FR_APP='ios';",
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        config.userContentController = content

        web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = ground
        web.scrollView.backgroundColor = ground
        web.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view.addSubview(web)

        camera.evaluate = { [weak self] script in
            await self?.runJS(script)
        }
        loadSite()
    }

    private func loadSite() {
        web.load(URLRequest(url: AppConfig.siteURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20))
    }

    @MainActor
    func runJS(_ script: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            web.evaluateJavaScript(script) { _, _ in done.resume() }
        }
    }

    // MARK: mensagens do app web

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "reload":
            loadSite()
        case "saveStart":
            // Envio em tempo real: grava a foto em Arquivos > No meu iPad > FOTO REAL > <projeto>
            guard let id = body["id"] as? String, let name = body["name"] as? String else { return }
            let folder = clean((body["folder"] as? String) ?? "fotos")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("FOTO REAL", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(clean(name))
            FileManager.default.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) { saves[id] = handle }
        case "saveChunk":
            guard let id = body["id"] as? String, let text = body["b64"] as? String,
                  let data = Data(base64Encoded: text), let handle = saves[id] else { return }
            try? handle.write(contentsOf: data)
        case "saveEnd":
            if let id = body["id"] as? String, let handle = saves.removeValue(forKey: id) { try? handle.close() }
        case "setURL":
            if let text = body["url"] as? String { AppConfig.saveSite(text) }
            loadSite()
        default:
            camera.handle(cmd: cmd, body: body)
        }
    }

    private func clean(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "..", with: "-")
        return t.isEmpty ? "foto" : t
    }

    // MARK: navegação

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           ["http", "https"].contains(url.scheme ?? ""),
           url.host != AppConfig.siteURL.host {
            UIApplication.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOffline(error.localizedDescription)
    }

    private func showOffline(_ reason: String) {
        let site = AppConfig.siteURL.absoluteString
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>body{margin:0;background:#0E0E10;color:#F4F4F5;font:16px -apple-system,system-ui,sans-serif;padding:max(48px,env(safe-area-inset-top)) 20px 20px}
        h1{font-size:24px;margin:0 0 6px}h1 span{color:#B8F232}p{color:#9A9AA3;line-height:1.45}
        input{width:100%;box-sizing:border-box;padding:14px;border-radius:12px;border:1px solid #2E2E34;background:#232327;color:#F4F4F5;font:inherit;margin-top:8px}
        button{width:100%;padding:15px;border-radius:14px;border:0;font:700 16px -apple-system,system-ui,sans-serif;margin-top:12px;background:#232327;color:#F4F4F5}
        .p{background:#B8F232;color:#142000}</style></head><body>
        <h1>FOTO <span>REAL</span></h1><p>Não consegui abrir o app. Confira a internet e o endereço do seu site.</p>
        <label for="u">Endereço do site</label><input id="u" value="\(site)" autocapitalize="off" autocorrect="off" inputmode="url">
        <button class="p" onclick="webkit.messageHandlers.fotoreal.postMessage({cmd:'setURL',url:document.getElementById('u').value})">Abrir</button>
        <button onclick="webkit.messageHandlers.fotoreal.postMessage({cmd:'reload'})">Tentar de novo</button>
        <p style="font-size:13px">Detalhe: \(reason.replacingOccurrences(of: "<", with: ""))</p></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    // MARK: arquivos que o app web manda salvar (ZIP, fotos, presets)

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saidas", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: target)
        downloadTargets[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        pendingShares.append(url)
        presentNextShare()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
    }

    private func presentNextShare() {
        guard !sharing, !pendingShares.isEmpty else { return }
        sharing = true
        let url = pendingShares.removeFirst()
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.sharing = false
            self?.presentNextShare()
        }
        present(sheet, animated: true)
    }
}

/// Evita que o app web e a tela fiquem presos um ao outro na memória.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
