import Foundation
import ImageCaptureCore

/// Conversa com a câmera ligada no cabo USB‑C usando o ImageCaptureCore da Apple
/// e entrega cada foto ao FOTO REAL.
///
/// Câmeras Canon travam o disparo enquanto o aparelho mantém a conexão aberta.
/// Por isso o modo padrão ("interval") abre a conexão só por alguns segundos de tempos em tempos,
/// traz as fotos novas e fecha de novo, deixando a câmera livre para fotografar.
final class CameraBridge: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    /// Roda um comando JavaScript dentro do app web.
    var evaluate: ((String) async -> Void)?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var started = false
    private var sessionOpen = false
    private var catalogReady = false

    private var autoImport = true
    private var mode = "jpg"            // "jpg", "raw" ou "both"
    private var syncMode = "interval"   // "interval" (câmera livre) ou "live" (conexão sempre aberta)
    private var every: TimeInterval = 15
    private var timer: Timer?

    private var baseline: Set<String>?  // arquivos que já estavam no cartão quando a câmera foi ligada
    private var received = Set<String>()
    private var queue: [ICCameraFile] = []
    private var busy = false
    private var pendingImportAll = false
    private var current: String?
    private var lastSync: Date?
    private var lastError: String?

    private lazy var folder: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: comandos vindos do app web

    func handle(cmd: String, body: [String: Any]) {
        if let m = body["mode"] as? String { mode = m }
        if let a = body["auto"] as? Bool { autoImport = a }
        if let s = body["sync"] as? String { syncMode = s }
        if let e = body["every"] as? NSNumber, e.doubleValue >= 5 { every = e.doubleValue }
        switch cmd {
        case "start": start()
        case "importAll": importAll()
        case "syncNow": openSession()
        default: break
        }
        schedule()
        if syncMode == "live" { openSession() } else { maybeClose() }
        pushStatus()
    }

    private func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.requestContentsAuthorization { [weak self] _ in
            self?.browser.requestControlAuthorization { _ in
                DispatchQueue.main.async {
                    self?.browser.start()
                    self?.pushStatus()
                }
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard camera != nil, !busy else { return }
        if !sessionOpen { openSession() }
    }

    // MARK: conexão com a câmera

    private func openSession() {
        guard let cam = camera, !sessionOpen else { return }
        catalogReady = false
        cam.requestOpenSession()
        pushStatus()
        // Algumas câmeras não avisam quando o catálogo fica pronto ao reabrir a conexão.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.sessionOpen, !self.catalogReady else { return }
            self.catalogReady = true
            self.processCatalog()
        }
    }

    private func maybeClose() {
        guard syncMode == "interval", sessionOpen, catalogReady, !busy, queue.isEmpty, !pendingImportAll else { return }
        camera?.requestCloseSession()
        sessionOpen = false
        catalogReady = false
        lastSync = Date()
        pushStatus()
    }

    private func processCatalog() {
        guard let cam = camera else { return }
        let files = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        if baseline == nil {
            baseline = Set(files.map { key($0) })
        } else if autoImport {
            for f in files where !(baseline?.contains(key(f)) ?? false) && wanted(f.name ?? "") {
                enqueue(f)
            }
        }
        if pendingImportAll {
            pendingImportAll = false
            for f in files where wanted(f.name ?? "") { enqueue(f) }
        }
        pushStatus()
        maybeClose()
    }

    private func importAll() {
        guard camera != nil else { return }
        pendingImportAll = true
        if sessionOpen && catalogReady { processCatalog() } else { openSession() }
    }

    // MARK: escolha dos arquivos

    private func wanted(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["mp4", "mov"].contains(ext) { return true }
        let jpg = ["jpg", "jpeg", "hif", "heic", "heif"].contains(ext)
        let raw = ["cr3", "cr2", "crw", "dng", "nef", "arw", "raf", "orf", "rw2"].contains(ext)
        switch mode {
        case "raw": return raw
        case "both": return jpg || raw
        default: return jpg
        }
    }

    private func key(_ file: ICCameraFile) -> String { "\(file.name ?? "")|\(file.fileSize)" }

    private func enqueue(_ file: ICCameraFile) {
        let k = key(file)
        guard !received.contains(k), !queue.contains(where: { key($0) == k }) else { return }
        queue.append(file)
        next()
    }

    // MARK: download, um arquivo por vez

    private func next() {
        guard !busy else { return }
        guard let cam = camera, sessionOpen, !queue.isEmpty else {
            current = nil
            pushStatus()
            maybeClose()
            return
        }
        busy = true
        let file = queue.removeFirst()
        current = file.name
        pushStatus()
        let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: folder, .overwrite: true]
        cam.requestDownloadFile(file, options: options, downloadDelegate: self,
                                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                                contextInfo: nil)
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        let name = file.name ?? "foto.jpg"
        let saved = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? name
        let url = folder.appendingPathComponent(saved)
        received.insert(key(file))
        if let error = error { lastError = error.localizedDescription }
        Task { [weak self] in
            if error == nil { await self?.send(url, name: name) }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self?.busy = false
                self?.next()
            }
        }
    }

    /// Manda o arquivo ao app web em pedaços (não cabe tudo de uma vez).
    private func send(_ url: URL, name: String) async {
        guard let data = try? Data(contentsOf: url), let evaluate = evaluate else { return }
        let id = UUID().uuidString
        let b64 = data.base64EncodedString()
        await evaluate("window.FR_native&&FR_native.fileStart('\(id)',\(jsString(name)),\(data.count))")
        let step = 1_000_000
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: step, limitedBy: b64.endIndex) ?? b64.endIndex
            await evaluate("window.FR_native&&FR_native.chunk('\(id)','\(b64[i..<j])')")
            i = j
        }
        await evaluate("window.FR_native&&FR_native.fileEnd('\(id)')")
    }

    private func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: d, encoding: .utf8) else { return "\"foto.jpg\"" }
        return String(text.dropFirst().dropLast())
    }

    func pushStatus() {
        var o: [String: Any] = ["connected": camera != nil,
                                "searching": started && camera == nil,
                                "auto": autoImport,
                                "mode": mode,
                                "sync": syncMode,
                                "every": Int(every),
                                "open": sessionOpen]
        if let cam = camera {
            o["name"] = cam.name ?? "Câmera"
            if let b = baseline { o["items"] = max(b.count, cam.mediaFiles?.count ?? 0) }
        }
        if let cur = current { o["downloading"] = cur; o["queue"] = queue.count }
        if let t = lastSync { o["lastSync"] = Int(Date().timeIntervalSince(t)) }
        if let err = lastError { o["error"] = err }
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: d, encoding: .utf8) else { return }
        Task { [weak self] in await self?.evaluate?("window.FR_native&&FR_native.status(\(json))") }
    }

    private func reset() {
        camera = nil
        sessionOpen = false
        catalogReady = false
        baseline = nil
        queue.removeAll()
        busy = false
        current = nil
        pendingImportAll = false
        pushStatus()
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        camera = cam
        cam.delegate = self
        openSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera { reset() }
    }

    // MARK: ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        if device === camera { reset() }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error = error {
            lastError = error.localizedDescription
            sessionOpen = false
        } else {
            sessionOpen = true
        }
        pushStatus()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        sessionOpen = false
        catalogReady = false
        pushStatus()
    }

    // MARK: ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        catalogReady = true
        processCatalog()
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        // Fotos tiradas com a conexão aberta (modo "ao vivo") chegam por aqui.
        guard catalogReady, baseline != nil, autoImport else { return }
        for item in items {
            if let file = item as? ICCameraFile, wanted(file.name ?? "") { enqueue(file) }
        }
        pushStatus()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { pushStatus() }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { pushStatus() }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { pushStatus() }
}
