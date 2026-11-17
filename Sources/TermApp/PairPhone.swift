import AppKit
import CoreImage
import Network
import SwiftUI
import SystemConfiguration
import TermHost

@MainActor
final class PairModel: ObservableObject {
    static let shared = PairModel()

    @Published private(set) var qr: NSImage?
    @Published private(set) var remoteLogin = false
    @Published private(set) var paired: String?
    @Published private(set) var problem: String?
    @Published private(set) var address = ""
    private var listener: NWListener?
    private var token = ""
    private var issued = Date.distantPast
    private var checker: Timer?
    private var open = 0

    func start() {
        paired = nil
        problem = nil
        loadPhones()
        checkRemoteLogin()
        checker?.invalidate()
        checker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { PairModel.shared.tick() }
        }
        newCode()
    }

    private func newCode() {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        issued = Date()
        qr = nil
        startListener()
    }

    private func tick() {
        checkRemoteLogin()
        if paired == nil, Date().timeIntervalSince(issued) > Pairing.lifetime { newCode() }
    }


    struct PairedPhone: Identifiable, Hashable {
        let id: String
        let name: String
        let line: String
    }
    @Published private(set) var phones: [PairedPhone] = []

    private static var authorizedKeys: String { NSHomeDirectory() + "/.ssh/authorized_keys" }

    func loadPhones() {
        let text = (try? String(contentsOfFile: Self.authorizedKeys, encoding: .utf8)) ?? ""
        phones = text.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("restrict,command=\""), line.contains("terminessd stdio\"") else { return nil }
            guard let end = line.range(of: "stdio\" ") else { return nil }
            let parts = line[end.upperBound...].split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { return nil }
            let name = parts.count == 3 ? String(parts[2]) : "iPhone"
            return PairedPhone(id: String(parts[1]), name: name == "terminess-iphone" ? "iPhone" : name, line: line)
        }
    }

    func remove(_ phone: PairedPhone) {
        let file = Self.authorizedKeys
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { String($0) != phone.line }
        do {
            try kept.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        } catch {
            problem = "Couldn't update ~/.ssh/authorized_keys: \(error.localizedDescription)"
            return
        }
        if let exe = HostService.executable {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-U", String(getuid()), "-f", "^\(NSRegularExpression.escapedPattern(for: exe)) stdio$"]
            try? kill.run()
        }
        if let fd = UnixSocket.connect(HostPaths.socket) {
            _ = Connection.writeAll(fd, Wire.Frame.control(Message(op: "revoke-push", key: phone.id)).encoded())
            close(fd)
        }
        loadPhones()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        token = ""
        checker?.invalidate()
        checker = nil
    }

    func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private func checkRemoteLogin() {
        DispatchQueue.global().async {
            let on = Self.portOpen(22)
            DispatchQueue.main.async { if PairModel.shared.remoteLogin != on { PairModel.shared.remoteLogin = on } }
        }
    }

    nonisolated private static func portOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }


    private func startListener() {
        listener?.cancel()
        guard let l = try? NWListener(using: .tcp, on: .any) else { problem = "Couldn't open a pairing port."; return }
        l.newConnectionHandler = { conn in
            MainActor.assumeIsolated {
                let model = PairModel.shared
                guard model.open < 4 else { conn.cancel(); return }
                model.open += 1
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .cancelled, .failed: MainActor.assumeIsolated { PairModel.shared.open -= 1 }
                    default: break
                    }
                }
                conn.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { conn.cancel() }
                model.receive(conn, buffer: Data())
            }
        }
        l.stateUpdateHandler = { state in
            guard case .ready = state, let port = l.port?.rawValue else { return }
            DispatchQueue.main.async { PairModel.shared.makeLink(pairPort: port) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func makeLink(pairPort: UInt16) {
        let net = Self.addresses()
        let reach = net.tailscale ?? net.localName
        let pairHost = net.tailscale ?? net.lan ?? net.localName
        address = reach
        guard let exe = HostService.executable else { problem = "terminessd isn't bundled with this build."; return }
        let hostKey = (try? String(contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8))?
            .split(separator: " ").prefix(2).joined(separator: " ")
        var c = URLComponents()
        c.scheme = "terminess"
        c.host = "add"
        c.queryItems = [
            URLQueryItem(name: "name", value: Host.current().localizedName ?? "Mac"),
            URLQueryItem(name: "address", value: reach),
            URLQueryItem(name: "user", value: NSUserName()),
            URLQueryItem(name: "port", value: "22"),
            URLQueryItem(name: "path", value: exe),
            URLQueryItem(name: "pair", value: "http://\(pairHost):\(pairPort)/pair"),
            URLQueryItem(name: "token", value: token),
        ] + (hostKey.map { [URLQueryItem(name: "hostkey", value: $0)] } ?? [])
        guard let link = c.url?.absoluteString.replacingOccurrences(of: "+", with: "%2B") else { return }
        qr = Self.qrImage(link)
    }

    private static func qrImage(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private static func addresses() -> (tailscale: String?, lan: String?, localName: String) {
        var tailscale: String?, lan: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
                guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host), name = String(cString: p.pointee.ifa_name)
                let parts = ip.split(separator: ".").compactMap { Int($0) }
                if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { tailscale = ip }
                else if name == "en0" || (lan == nil && name.hasPrefix("en")) { lan = ip }
            }
            freeifaddrs(ifaddr)
        }
        let local = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? ProcessInfo.processInfo.hostName
        return (tailscale, lan, local)
    }


    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, done, error in
            MainActor.assumeIsolated {
                var buf = buffer
                if let data { buf.append(data) }
                if let request = Self.completeRequest(buf) {
                    let (status, reply) = PairModel.shared.handle(request)
                    let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
                    let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                        conn.cancel()
                        if status == 200 { MainActor.assumeIsolated { PairModel.shared.closeListener() } }
                    })
                } else if done || error != nil || buf.count > Pairing.maxRequest {
                    conn.cancel()
                } else {
                    PairModel.shared.receive(conn, buffer: buf)
                }
            }
        }
    }

    nonisolated private static func completeRequest(_ buf: Data) -> [String: String]? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        guard head.hasPrefix("POST /pair ") else { return [:] }
        guard let length = Pairing.contentLength(head: head) else { return [:] }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: String] ?? [:]
    }

    private func closeListener() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ req: [String: String]) -> (Int, [String: String]) {
        func fail(_ status: Int, _ message: String) -> (Int, [String: String]) { (status, ["result": message]) }
        guard !token.isEmpty, Date().timeIntervalSince(issued) <= Pairing.lifetime else { return fail(403, "pairing code expired") }
        guard let key = req["key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              key.range(of: #"^(ecdsa-sha2-nistp256|ssh-ed25519) [A-Za-z0-9+/=]{40,800}( [^\n]{0,80})?$"#, options: .regularExpression) != nil
        else { return fail(400, "not an SSH public key") }
        guard let proof = req["proof"], Pairing.verify(code: token, key: key, proof: proof)
        else { return fail(403, "wrong or used pairing code") }
        guard let exe = HostService.executable else { return fail(500, "no terminessd") }
        do {
            try Self.authorize(key, command: exe)
        } catch {
            problem = "Couldn't update ~/.ssh/authorized_keys: \(error.localizedDescription)"
            return fail(500, "couldn't save the key")
        }
        let reply = Pairing.reply(code: token, key: key)
        token = ""
        loadPhones()
        SidebarModel.shared.refreshPair()
        paired = key.split(separator: " ").dropFirst(2).joined(separator: " ")
        if paired?.isEmpty != false { paired = "your iPhone" }
        return (200, ["result": "paired", "proof": reply])
    }

    private static func authorize(_ key: String, command: String) throws {
        let dir = NSHomeDirectory() + "/.ssh"
        let file = dir + "/authorized_keys"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let blob = key.split(separator: " ")[1]
        if existing.contains(blob) { return }
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let line = "restrict,command=\"\(escaped) stdio\" \(key)\n"
        let text = existing.isEmpty || existing.hasSuffix("\n") ? existing + line : existing + "\n" + line
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}

struct PairPhoneView: View {
    @ObservedObject var model = PairModel.shared
    @State private var confirmRemove: PairModel.PairedPhone?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pair your iPhone").font(.title2.bold())
            Text("Pick up what's running on this Mac from Terminess for iPhone.").foregroundStyle(.secondary)
            step(1, model.remoteLogin ? "Remote Login is on." : "Turn on Remote Login, so your iPhone can connect over SSH.") {
                if model.remoteLogin {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Open Sharing Settings") { model.openSharingSettings() }
                }
            }
            step(2, "Scan this code with your iPhone's camera, then open it in Terminess.") { EmptyView() }
            HStack {
                Spacer()
                Group {
                    if let qr = model.qr {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 230, height: 230)
                            .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    } else {
                        ProgressView().frame(width: 258, height: 258)
                    }
                }
                Spacer()
            }
            if let paired = model.paired {
                Label("Paired with \(paired). Your sessions here now show on the phone.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Your iPhone connects to \(model.address.isEmpty ? "this Mac" : model.address). It needs to be on the same Wi-Fi, or both devices on Tailscale.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.red) }
            if !model.phones.isEmpty {
                Divider()
                Text("Paired phones").font(.headline)
                ForEach(model.phones) { phone in
                    HStack {
                        Image(systemName: "iphone")
                        Text(phone.name)
                        Text(String(phone.id.suffix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { confirmRemove = phone }
                    }
                }
                Text("Remove a phone you've lost or replaced. It's disconnected straight away and can't connect again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 420)
        .confirmationDialog("Remove \(confirmRemove?.name ?? "this phone")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { phone in
            Button("Remove", role: .destructive) { model.remove(phone) }
        } message: { _ in Text("It won't be able to connect to this Mac until you pair it again.") }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func step<Accessory: View>(_ n: Int, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.bold()).frame(width: 22, height: 22).background(Circle().fill(.quaternary))
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory()
        }
    }
}
