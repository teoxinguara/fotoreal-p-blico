import UIKit
import WebKit
import Photos

/// Tela única do app: mostra o FOTO REAL (o mesmo do site) e liga a câmera do cabo a ele.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private var web: WKWebView!
    private let camera = CameraBridge()
    private let scheme = SiteSchemeHandler()
    private var checkedUpdate = false
    private var downloadTargets: [ObjectIdentifier: URL] = [:]
    private var pendingShares: [URL] = []
    private var sharing = false
    private var saves: [String: FileHandle] = [:]
    private var saveInfo: [String: (url: URL, album: String, video: Bool)] = [:]
    private let ground = UIColor(red: 14 / 255, green: 14 / 255, blue: 16 / 255, alpha: 1)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ground

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.setURLSchemeHandler(scheme, forURLScheme: "fotoreal")
        let content = WKUserContentController()
        content.add(WeakMessageHandler(self), name: "fotoreal")
        content.addUserScript(WKUserScript(source: "window.FR_APP='ios';window.FR_APPV='2.0';",
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
        LocalSite.clearInbox()
        loadSite()
    }

    /// Abre o FOTO REAL de dentro do app (funciona sem internet) ou o site, conforme a escolha em Config.
    private func loadSite() {
        if AppConfig.useLocal && LocalSite.available {
            web.load(URLRequest(url: LocalSite.start))
        } else {
            web.load(URLRequest(url: AppConfig.siteURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20))
        }
    }

    private func checkUpdate(manual: Bool) {
        LocalSite.checkUpdate(site: AppConfig.siteURL) { [weak self] version, message in
            Task { @MainActor in
                guard let self = self else { return }
                if let v = version {
                    self.web.evaluateJavaScript("window.FR_native&&FR_native.update&&FR_native.update('\(v)')", completionHandler: nil)
                } else if manual {
                    let text = (try? JSONSerialization.data(withJSONObject: [message])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                    self.web.evaluateJavaScript("window.FR_native&&FR_native.updateNone&&FR_native.updateNone(\(text)[0])", completionHandler: nil)
                }
            }
        }
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
            if (body["kind"] as? String) == "photos" {
                // Salvar na galeria: grava num arquivo temporário e depois manda para o app Fotos
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("galeria", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(UUID().uuidString + "-" + clean(name))
                FileManager.default.createFile(atPath: url.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: url) {
                    saves[id] = handle
                    saveInfo[id] = (url, (body["album"] as? String) ?? "", (body["video"] as? Bool) ?? false)
                } else {
                    reply(id, ok: false, "Não consegui preparar a foto")
                }
                return
            }
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
            guard let id = body["id"] as? String else { return }
            if let handle = saves.removeValue(forKey: id) { try? handle.close() }
            if let info = saveInfo.removeValue(forKey: id) {
                saveToPhotos(id: id, url: info.url, album: info.album, video: info.video)
            } else {
                reply(id, ok: true, "")
            }
        case "inDone":
            if let id = body["id"] as? String, !id.contains("/"), !id.contains("..") {
                try? FileManager.default.removeItem(at: LocalSite.inbox.appendingPathComponent(id))
            }
        case "setMode":
            AppConfig.setMode((body["mode"] as? String) ?? "local")
            loadSite()
        case "checkUpdate":
            checkUpdate(manual: true)
        case "setURL":
            if let text = body["url"] as? String { AppConfig.saveSite(text) }
            loadSite()
        default:
            camera.handle(cmd: cmd, body: body)
        }
    }

    // MARK: salvar no app Fotos

    private func reply(_ id: String, ok: Bool, _ msg: String) {
        let text = (try? JSONSerialization.data(withJSONObject: [msg])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let script = "window.FR_native&&FR_native.saved&&FR_native.saved('\(id)',\(ok),\(text)[0])"
        web.evaluateJavaScript(script, completionHandler: nil)
    }

    private func saveToPhotos(id: String, url: URL, album: String, video: Bool) {
        PhotoSaver.save(url: url, album: album, video: video) { [weak self] ok, msg in
            Task { @MainActor in self?.reply(id, ok: ok, msg) }
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        camera.localScheme = webView.url?.scheme == "fotoreal"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.scheme == "fotoreal" && !checkedUpdate {
            checkedUpdate = true
            checkUpdate(manual: false)
        }
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
        \(LocalSite.available ? "<button class=\"p\" onclick=\"webkit.messageHandlers.fotoreal.postMessage({cmd:'setMode',mode:'local'})\">Usar sem internet</button>" : "")
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

/// Grava fotos e vídeos no app Fotos, dentro de um álbum com o nome escolhido.
enum PhotoSaver {
    static func save(url: URL, album: String, video: Bool, done: @escaping (Bool, String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            if status == .authorized || status == .limited {
                write(url: url, album: status == .authorized ? album : "", video: video, done: done)
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { add in
                if add == .authorized {
                    write(url: url, album: "", video: video, done: done)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    done(false, "Sem permissão para o app Fotos. Abra Ajustes › FOTO REAL › Fotos e escolha Acesso total.")
                }
            }
        }
    }

    private static func findAlbum(_ title: String) -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    private static func write(url: URL, album: String, video: Bool, done: @escaping (Bool, String) -> Void) {
        let name = album.trimmingCharacters(in: .whitespaces)
        let existing = name.isEmpty ? nil : findAlbum(name)
        let original = String(url.lastPathComponent.dropFirst(37))
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            let o = PHAssetResourceCreationOptions()
            if !original.isEmpty { o.originalFilename = original }
            req.addResource(with: video ? .video : .photo, fileURL: url, options: o)
            guard !name.isEmpty, let placeholder = req.placeholderForCreatedAsset else { return }
            if let col = existing {
                PHAssetCollectionChangeRequest(for: col)?.addAssets([placeholder] as NSArray)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).addAssets([placeholder] as NSArray)
            }
        }) { ok, error in
            try? FileManager.default.removeItem(at: url)
            done(ok, ok ? "" : (error?.localizedDescription ?? "Erro ao salvar"))
        }
    }
}
