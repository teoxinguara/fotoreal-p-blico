import Foundation
import ImageCaptureCore
import UIKit

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

    // Modo remoto da Canon (o mesmo que o EOS Utility usa): deixa a câmera livre com o cabo ligado
    private var canonMode = false
    private var canonTried = false
    private var polling = false
    private var pollTimer: Timer?
    private var txid: UInt32 = 1
    private var canonQueue: [(UInt32, String, Int)] = []
    private var knownHandles = Set<UInt32>()
    private var candidates = Set<UInt32>()
    private var baselineMissing = true
    private var sawNewObject = false
    private var pollCount = 0
    private var eventCount = 0
    private var found = 0
    private var gotCount = 0
    private var diag = ""
    private var canonDone = Set<UInt32>()
    private var isCanon: Bool { (camera?.name ?? "").lowercased().contains("canon") }

    // Wi‑Fi por FTP
    private let ftp = FTPServer()
    private var ftpQueue: [(URL, String)] = []
    private var ftpBusy = false

    override init() {
        super.init()
        ftp.onFile = { [weak self] url, name in
            DispatchQueue.main.async { self?.ftpQueue.append((url, name)); self?.ftpNext() }
        }
        ftp.onStatus = { [weak self] in self?.pushStatus() }
    }

    private func ftpNext() {
        guard !ftpBusy, !ftpQueue.isEmpty else { return }
        ftpBusy = true
        let (url, name) = ftpQueue.removeFirst()
        Task { [weak self] in
            await self?.send(url, name: name)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self?.ftpBusy = false
                self?.ftpNext()
            }
        }
    }

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
        case "ftpStart":
            if let p = body["pass"] as? String { ftp.pass = p }
            let port = (body["port"] as? NSNumber)?.intValue ?? 2121
            ftp.start(port: UInt16(max(1024, min(65535, port))))
            UIApplication.shared.isIdleTimerDisabled = true
        case "ftpStop":
            ftp.stop()
            UIApplication.shared.isIdleTimerDisabled = false
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
        guard camera != nil, !busy, !canonMode else { return }
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
        if isCanon && (canonMode || !canonTried) { return }
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
                                "open": sessionOpen,
                                "canon": canonMode,
                                "diag": diag,
                                "events": eventCount,
                                "found": found,
                                "got": gotCount]
        if let cam = camera {
            o["name"] = cam.name ?? "Câmera"
            if let b = baseline { o["items"] = max(b.count, cam.mediaFiles?.count ?? 0) }
        }
        if let cur = current { o["downloading"] = cur; o["queue"] = queue.count }
        if let t = lastSync { o["lastSync"] = Int(Date().timeIntervalSince(t)) }
        if let err = lastError { o["error"] = err }
        o["ftpOn"] = ftp.running
        o["ftpPort"] = Int(ftp.port)
        o["ftpClients"] = ftp.clients
        o["ftpCount"] = ftp.count
        if let ip = FTPServer.localIP() { o["ftpIP"] = ip }
        if let f = ftp.lastFile { o["ftpLast"] = f }
        if let e = ftp.lastError { o["ftpErr"] = e }
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: d, encoding: .utf8) else { return }
        Task { [weak self] in await self?.evaluate?("window.FR_native&&FR_native.status(\(json))") }
    }

    private func reset() {
        pollTimer?.invalidate()
        pollTimer = nil
        canonMode = false
        canonTried = false
        polling = false
        canonQueue.removeAll()
        knownHandles.removeAll()
        candidates.removeAll()
        baselineMissing = true
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
            if isCanon && !canonMode { enableCanonRemote() }
        }
        pushStatus()
    }

    // MARK: modo remoto da Canon (PTP)

    private func rd32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < b.count else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private func rd16(_ b: [UInt8], _ o: Int) -> UInt16 {
        guard o + 1 < b.count else { return 0 }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    /// Manda um comando PTP para a câmera e devolve os dados e se deu certo.
    private func ptp(_ op: UInt16, _ params: [UInt32] = [], _ done: @escaping (Data?, Bool) -> Void) {
        guard let cam = camera else { done(nil, false); return }
        var bytes: [UInt8] = []
        func u32(_ v: UInt32) { bytes += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        func u16(_ v: UInt16) { bytes += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        u32(UInt32(12 + 4 * params.count)); u16(1); u16(op); u32(txid); params.forEach { u32($0) }
        txid = txid &+ 1
        cam.requestSendPTPCommand(Data(bytes), outData: nil) { [weak self] data, response, error in
            guard let self = self else { return }
            var payload = data
            let head = [UInt8](data.prefix(12))
            if head.count == 12 && self.rd16(head, 4) == 2 && self.rd16(head, 6) == op {
                payload = data.subdata(in: data.startIndex + 12 ..< data.endIndex)
            }
            var ok = error == nil
            let r = [UInt8](response.prefix(8))
            if r.count == 8 { ok = ok && self.rd16(r, 6) == 0x2001 }
            DispatchQueue.main.async { done(payload, ok) }
        }
    }

    private func enableCanonRemote() {
        ptp(0x9114, [1]) { [weak self] _, ok1 in           // SetRemoteMode
            self?.ptp(0x9115, [1]) { _, ok2 in               // SetEventMode
                guard let self = self else { return }
                self.canonTried = true
                self.canonMode = ok1 || ok2
                if self.canonMode {
                    // Guarda o que já está no cartão para trazer só as fotos novas.
                    self.listHandles { handles in
                        self.knownHandles = Set(handles)
                        if !handles.isEmpty { self.baselineMissing = false }
                        self.diag = "Cartão lido: \(handles.count) arquivos"
                        self.pushStatus()
                    }
                    self.pollTimer?.invalidate()
                    self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
                } else {
                    self.diag = "A câmera não aceitou o modo remoto"
                    self.maybeClose()
                }
                self.pushStatus()
            }
        }
    }

    /// Lista todos os arquivos do cartão (GetObjectHandles).
    private func listHandles(_ done: @escaping ([UInt32]) -> Void) {
        ptp(0x1007, [0xFFFFFFFF, 0, 0]) { [weak self] data, ok in
            guard let self = self, ok, let d = data else { done([]); return }
            let b = [UInt8](d)
            let n = Int(self.rd32(b, 0))
            var out: [UInt32] = []
            var i = 0
            while i < n && 4 + i * 4 + 3 < b.count { out.append(self.rd32(b, 4 + i * 4)); i += 1 }
            done(out)
        }
    }

    private func poll() {
        guard canonMode, !polling, !busy, camera != nil else { return }
        polling = true
        ptp(0x9116) { [weak self] data, _ in                 // GetEvent
            guard let self = self else { return }
            if let d = data { self.parseEvents([UInt8](d)) }
            self.pollCount += 1
            // A cada 3 segundos confere o cartão, mesmo sem aviso da câmera.
            if self.pollCount % 3 == 0 || self.sawNewObject {
                self.sawNewObject = false
                self.scanNew { self.polling = false; self.canonNext() }
            } else {
                self.polling = false
                self.canonNext()
            }
        }
    }

    private func parseEvents(_ b: [UInt8]) {
        var o = 0
        while o + 8 <= b.count {
            let size = Int(rd32(b, o)), type = rd32(b, o + 4)
            if size < 8 || o + size > b.count { break }
            if type == 0 && size == 8 { break }
            eventCount += 1
            if [0xC181, 0xC1A7, 0xC186, 0xC1A9, 0xC182, 0xC1A8].contains(type) {
                sawNewObject = true
                let handle = rd32(b, o + 8)
                if handle != 0 && !canonDone.contains(handle) && !knownHandles.contains(handle) { candidates.insert(handle) }
            }
            o += size
        }
    }

    /// Procura arquivos novos no cartão e coloca na fila.
    private func scanNew(_ done: @escaping () -> Void) {
        listHandles { [weak self] handles in
            guard let self = self else { done(); return }
            if self.knownHandles.isEmpty && !handles.isEmpty && self.baselineMissing {
                self.knownHandles = Set(handles); self.baselineMissing = false; done(); return
            }
            for h in handles where !self.knownHandles.contains(h) && !self.canonDone.contains(h) { self.candidates.insert(h) }
            self.inspect(Array(self.candidates), done)
        }
    }

    /// Lê nome e tamanho de cada arquivo novo (GetObjectInfo).
    private func inspect(_ list: [UInt32], _ done: @escaping () -> Void) {
        guard let h = list.first else { done(); return }
        let rest = Array(list.dropFirst())
        candidates.remove(h)
        if canonDone.contains(h) || canonQueue.contains(where: { $0.0 == h }) { inspect(rest, done); return }
        ptp(0x1008, [h]) { [weak self] data, ok in
            guard let self = self else { return }
            self.knownHandles.insert(h)
            guard ok, let d = data, d.count > 53 else { self.inspect(rest, done); return }
            let b = [UInt8](d)
            let format = self.rd16(b, 4)
            let size = Int(self.rd32(b, 8))
            let chars = Int(b[52])
            var name = ""
            var k = 53
            for _ in 0..<max(0, chars - 1) {
                let c = self.rd16(b, k); k += 2
                if c == 0 { break }
                if let u = UnicodeScalar(c) { name.append(Character(u)) }
            }
            if format != 0x3001 && !name.isEmpty && self.autoImport && self.wanted(name) {
                self.canonQueue.append((h, name, size))
                self.found += 1
            } else {
                self.canonDone.insert(h)
            }
            self.inspect(rest, done)
        }
    }

    private func canonNext() {
        guard !busy, !polling, !canonQueue.isEmpty else { return }
        busy = true
        let (handle, name, size) = canonQueue.removeFirst()
        current = name
        pushStatus()
        var buffer = Data()
        let chunk: UInt32 = 2_000_000
        func step() {
            ptp(0x101B, [handle, UInt32(buffer.count), chunk]) { [weak self] data, ok in   // GetPartialObject
                guard let self = self else { return }
                if ok, let d = data, !d.isEmpty {
                    buffer.append(d)
                    if size > 0 && buffer.count < size && d.count > 0 { step(); return }
                }
                self.canonDone.insert(handle)
                if buffer.count < 1000 || (size > 0 && buffer.count < size) {
                    self.diag = "Falhou ao baixar \(name)"
                    self.busy = false; self.current = nil; self.pushStatus(); self.canonNext()
                    return
                }
                let url = self.folder.appendingPathComponent(name)
                try? buffer.write(to: url)
                Task { [weak self] in
                    await self?.send(url, name: name)
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.ptp(0x9117, [handle]) { _, _ in }   // TransferComplete
                        self.gotCount += 1
                        self.diag = "Recebida: \(name)"
                        self.busy = false
                        self.current = nil
                        self.pushStatus()
                        self.canonNext()
                    }
                }
            }
        }
        step()
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
