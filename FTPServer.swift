import Foundation
import Network

/// Servidor FTP simples dentro do FOTO REAL.
/// A câmera (Canon, Nikon, Sony...) envia cada foto pelo Wi‑Fi logo depois do clique,
/// sem travar o disparo. Só modo passivo, sem TLS (escolha "FTP" na câmera, não FTPS/SFTP).
final class FTPServer {
    var onFile: ((URL, String) -> Void)?
    var onStatus: (() -> Void)?

    var user = "fotoreal"
    var pass = ""
    private(set) var port: UInt16 = 2121
    private(set) var running = false
    private(set) var clients = 0
    private(set) var count = 0
    private(set) var lastFile: String?
    private(set) var lastError: String?

    let queue = DispatchQueue(label: "fotoreal.ftp")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: FTPSession] = [:]

    func start(port: UInt16) {
        queue.async {
            if self.running && port == self.port { return }
            self.stopNow()
            self.port = port
            self.lastError = nil
            do {
                guard let p = NWEndpoint.Port(rawValue: port) else { return }
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: p)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready: self.running = true
                    case .failed(let e): self.lastError = "Servidor parou: \(e.localizedDescription)"; self.running = false
                    case .cancelled: self.running = false
                    default: break
                    }
                    self.notify()
                }
                l.start(queue: self.queue)
                self.listener = l
            } catch {
                self.lastError = "Não consegui ligar o servidor: \(error.localizedDescription)"
            }
            self.notify()
        }
    }

    func stop() { queue.async { self.stopNow(); self.notify() } }

    private func stopNow() {
        listener?.cancel()
        listener = nil
        sessions.values.forEach { $0.close() }
        sessions.removeAll()
        running = false
        clients = 0
    }

    private func accept(_ c: NWConnection) {
        let s = FTPSession(conn: c, server: self)
        sessions[ObjectIdentifier(s)] = s
        clients = sessions.count
        notify()
        s.start()
    }

    func ended(_ s: FTPSession) {
        sessions.removeValue(forKey: ObjectIdentifier(s))
        clients = sessions.count
        notify()
    }

    func received(_ url: URL, name: String) {
        count += 1
        lastFile = name
        notify()
        onFile?(url, name)
    }

    func notify() { DispatchQueue.main.async { self.onStatus?() } }

    /// Endereço do aparelho na rede Wi‑Fi (ou no Acesso Pessoal do iPhone).
    static func localIP() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = p.pointee
            guard let sa = item.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        if let ip = found["en0"] { return ip }
        if let ip = found["bridge100"] { return ip }
        return found.first(where: { $0.key != "lo0" && !$0.value.hasPrefix("127.") && !$0.key.hasPrefix("pdp_ip") })?.value
    }
}

/// Uma conexão de controle FTP (uma por câmera).
final class FTPSession {
    private let conn: NWConnection
    private weak var server: FTPServer?
    private var buffer = Data()
    private var authed = false
    private var cwd = "/"
    private var dataListener: NWListener?
    private var dataConn: NWConnection?
    private var pendingData: ((NWConnection) -> Void)?
    private var closed = false

    init(conn: NWConnection, server: FTPServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        guard let q = server?.queue else { return }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: q)
        reply(220, "FOTO REAL pronto")
        readMore()
    }

    func close() {
        dataListener?.cancel()
        dataConn?.cancel()
        conn.cancel()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        dataListener?.cancel()
        dataConn?.cancel()
        server?.ended(self)
    }

    private func send(_ text: String) {
        conn.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func reply(_ code: Int, _ text: String) { send("\(code) \(text)\r\n") }

    private func readMore() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.buffer.append(d)
                self.processLines()
            }
            if done || error != nil {
                self.conn.cancel()
                self.finish()
                return
            }
            self.readMore()
        }
    }

    private func processLines() {
        while let r = buffer.firstIndex(of: 10) {
            var lineData = buffer.subdata(in: buffer.startIndex..<r)
            buffer.removeSubrange(buffer.startIndex...r)
            if lineData.last == 13 { lineData.removeLast() }
            handle(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func resolve(_ path: String) -> String {
        if path.isEmpty { return cwd }
        var base = path.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init)
        for part in path.split(separator: "/").map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = base.popLast() } else { base.append(part) }
        }
        return "/" + base.joined(separator: "/")
    }

    private func handle(_ line: String) {
        let pieces = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = (pieces.first.map(String.init) ?? "").uppercased()
        let arg = pieces.count > 1 ? String(pieces[1]) : ""
        let open: Set<String> = ["USER", "PASS", "QUIT", "SYST", "FEAT", "OPTS", "AUTH", "NOOP"]
        if !authed && !open.contains(cmd) { reply(530, "Faça login primeiro"); return }

        switch cmd {
        case "USER":
            reply(331, "Digite a senha")
        case "PASS":
            if let s = server, s.pass.isEmpty || arg == s.pass {
                authed = true
                reply(230, "Conectado ao FOTO REAL")
            } else {
                reply(530, "Senha errada")
            }
        case "AUTH":
            reply(502, "Use FTP comum, sem FTPS")
        case "SYST":
            reply(215, "UNIX Type: L8")
        case "FEAT":
            send("211-Recursos\r\n PASV\r\n EPSV\r\n UTF8\r\n211 Fim\r\n")
        case "OPTS", "TYPE", "MODE", "STRU", "NOOP", "SITE":
            reply(200, "OK")
        case "ALLO":
            reply(202, "OK")
        case "PWD", "XPWD":
            reply(257, "\"\(cwd)\" é a pasta atual")
        case "CWD", "XCWD":
            cwd = resolve(arg)
            reply(250, "OK")
        case "CDUP", "XCUP":
            cwd = resolve("..")
            reply(250, "OK")
        case "MKD", "XMKD":
            reply(257, "\"\(resolve(arg))\" criada")
        case "RMD", "XRMD", "DELE":
            reply(250, "OK")
        case "RNFR":
            reply(350, "Aguardando o novo nome")
        case "RNTO":
            reply(250, "OK")
        case "SIZE", "MDTM":
            reply(550, "Arquivo não existe")
        case "REST":
            reply(502, "Não suportado")
        case "PORT", "EPRT":
            reply(502, "Ative o modo passivo na câmera")
        case "PASV":
            openPassive(extended: false)
        case "EPSV":
            openPassive(extended: true)
        case "LIST", "NLST", "MLSD":
            reply(150, "Enviando a lista")
            withData { [weak self] c in
                c.send(content: Data(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    c.cancel()
                    self?.dataConn = nil
                    self?.reply(226, "Lista enviada")
                })
            }
        case "STOR", "APPE", "STOU":
            let name = (arg as NSString).lastPathComponent.isEmpty ? "foto.jpg" : (arg as NSString).lastPathComponent
            reply(150, "Pode enviar")
            withData { [weak self] c in self?.receiveFile(c, name: name) }
        case "ABOR":
            dataConn?.cancel()
            dataConn = nil
            reply(226, "Cancelado")
        case "STAT":
            reply(211, "FOTO REAL")
        case "HELP":
            reply(214, "OK")
        case "QUIT":
            reply(221, "Até logo")
            conn.cancel()
        default:
            reply(502, "Comando não suportado")
        }
    }

    private func withData(_ f: @escaping (NWConnection) -> Void) {
        if let c = dataConn { f(c) } else { pendingData = f }
    }

    private func openPassive(extended: Bool) {
        dataListener?.cancel()
        dataListener = nil
        dataConn?.cancel()
        dataConn = nil
        pendingData = nil
        guard let q = server?.queue, let l = try? NWListener(using: .tcp, on: .any) else {
            reply(425, "Não consegui abrir a porta de dados")
            return
        }
        dataListener = l
        l.newConnectionHandler = { [weak self] c in
            guard let self = self else { return }
            self.dataConn = c
            c.start(queue: q)
            self.dataListener?.cancel()
            self.dataListener = nil
            if let p = self.pendingData {
                self.pendingData = nil
                p(c)
            }
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self = self, case .ready = state, let port = l.port?.rawValue else { return }
            if extended {
                self.reply(229, "Modo passivo (|||\(port)|)")
            } else {
                let ip = (FTPServer.localIP() ?? "0.0.0.0").replacingOccurrences(of: ".", with: ",")
                self.reply(227, "Modo passivo (\(ip),\(port / 256),\(port % 256))")
            }
        }
        l.start(queue: q)
    }

    private func receiveFile(_ c: NWConnection, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-\(UUID().uuidString)-\(name)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            reply(451, "Não consegui gravar o arquivo")
            c.cancel()
            return
        }
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                if let d = data, !d.isEmpty { try? handle.write(contentsOf: d) }
                if done || error != nil {
                    try? handle.close()
                    c.cancel()
                    self?.dataConn = nil
                    if error == nil {
                        self?.reply(226, "Foto recebida")
                        self?.server?.received(url, name: name)
                    } else {
                        self?.reply(426, "A conexão caiu")
                        try? FileManager.default.removeItem(at: url)
                    }
                    return
                }
                loop()
            }
        }
        loop()
    }
}
