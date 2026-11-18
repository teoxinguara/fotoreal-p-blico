import Foundation
import ImageCaptureCore

/// Conversa com a câmera ligada no cabo USB‑C (Canon, Nikon, Sony...) usando o ImageCaptureCore da Apple
/// e entrega cada foto ao FOTO REAL. Fotos tiradas com a câmera ligada chegam sozinhas.
final class CameraBridge: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    /// Roda um comando JavaScript dentro do app web.
    var evaluate: ((String) async -> Void)?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var catalogReady = false
    private var autoImport = true
    private var mode = "jpg"           // "jpg", "raw" ou "both"
    private var started = false
    private var received = Set<String>()
    private var queue: [ICCameraFile] = []
    private var busy = false
    private var current: String?
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
        switch cmd {
        case "start": start()
        case "importAll": importAll()
        default: break
        }
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

    private func importAll() {
        guard let cam = camera else { return }
        for item in cam.mediaFiles ?? [] {
            if let file = item as? ICCameraFile, wanted(file.name ?? "") { enqueue(file) }
        }
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
        guard let cam = camera, !queue.isEmpty else {
            current = nil
            pushStatus()
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
                                "mode": mode]
        if let cam = camera {
            o["name"] = cam.name ?? "Câmera"
            if catalogReady { o["items"] = cam.mediaFiles?.count ?? 0 }
        }
        if let cur = current { o["downloading"] = cur; o["queue"] = queue.count }
        if let err = lastError { o["error"] = err }
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: d, encoding: .utf8) else { return }
        Task { [weak self] in await self?.evaluate?("window.FR_native&&FR_native.status(\(json))") }
    }

    private func reset() {
        camera = nil
        catalogReady = false
        queue.removeAll()
        busy = false
        current = nil
        pushStatus()
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        camera = cam
        catalogReady = false
        cam.delegate = self
        cam.requestOpenSession()
        pushStatus()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera { reset() }
    }

    // MARK: ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        if device === camera { reset() }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error = error { lastError = error.localizedDescription }
        pushStatus()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    // MARK: ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        catalogReady = true
        pushStatus()
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        // Antes do catálogo ficar pronto, os itens são as fotos que já estavam no cartão.
        // Depois disso, cada item novo é uma foto que você acabou de tirar.
        guard catalogReady else { return }
        if autoImport {
            for item in items {
                if let file = item as? ICCameraFile, wanted(file.name ?? "") { enqueue(file) }
            }
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
