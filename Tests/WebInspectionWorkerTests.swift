import Foundation
import AppKit
import Darwin

/// Loopback HTTP fixture serving a page plus worker scripts; records every request line.
final class WorkerSite: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let port: UInt16
    private let listener: Int32
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return log }
    init(routes: [String: (type: String, body: String)]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw nativeFailure("socket") }
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw nativeFailure("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        listener = fd; port = UInt16(bigEndian: address.sin_port)
        let listener = self.listener
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 65536)
                let count = read(client, &buffer, buffer.count)
                let line = (count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : "").components(separatedBy: "\r\n").first ?? ""
                self?.lock.lock(); self?.log.append(line); self?.lock.unlock()
                let parts = line.split(separator: " "), path = parts.count > 1 ? String(parts[1]) : ""
                let route = parts.first == "GET" ? routes[path] : nil
                let body = Data((route?.body ?? "not found").utf8)
                let header = "HTTP/1.1 \(route == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(route?.type ?? "text/plain"); charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                let reply = Data(header.utf8) + body
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                close(client)
            }
        }
    }
    deinit { close(listener) }
}

/// Web inspection promises GET only. Page-level guards do not run inside worker
/// realms, so every worker kind must be refused before it can send anything.
@main struct WebInspectionWorkerTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        // Each worker, if it ever runs, POSTs (fetch and XHR) to a path naming itself.
        let send = { (name: String) in "fetch('/post-\(name)', {method: 'POST', body: 'x'}).catch(() => {}); try { const x = new XMLHttpRequest(); x.open('POST', '/xhr-\(name)'); x.send('x'); } catch (e) {}" }
        let page = """
        <!doctype html><html><head><title>Worker probe</title></head><body><ul id="status"></ul><script>
        const report = (what) => { const li = document.createElement('li'); li.textContent = what; document.getElementById('status').appendChild(li); };
        const attempt = (name, make) => { try { const w = make(); report(name + ': started'); return w; } catch (e) { report(name + ': refused'); } };
        attempt('dedicated', () => new Worker('/worker.js'));
        attempt('module', () => new Worker('/worker.js', {type: 'module'}));
        attempt('blob', () => new Worker(URL.createObjectURL(new Blob([\(try nativeJSON(send("blob")))], {type: 'text/javascript'}))));
        attempt('data', () => new Worker('data:text/javascript,' + encodeURIComponent(\(try nativeJSON(send("data"))))));
        attempt('shared', () => new SharedWorker('/shared.js'));
        // A worker constructor recovered from a fresh same-origin frame realm.
        attempt('frame-realm', () => { const f = document.createElement('iframe'); document.body.appendChild(f); return new f.contentWindow.Worker('/worker.js'); });
        attempt('frame-realm-shared', () => { const f = document.createElement('iframe'); document.body.appendChild(f); return new f.contentWindow.SharedWorker('/shared.js'); });
        // The page fetch guard must also hold in a fresh frame realm.
        try { const f = document.createElement('iframe'); document.body.appendChild(f); f.contentWindow.fetch('/post-frame-fetch', {method: 'POST', body: 'x'}).then(() => report('frame-fetch: sent'), () => report('frame-fetch: refused')); } catch (e) { report('frame-fetch: refused'); }
        if (navigator.serviceWorker) navigator.serviceWorker.register('/sw.js').then(() => report('service: registered'), () => report('service: refused'));
        else report('service: unavailable');
        </script></body></html>
        """
        let site = try WorkerSite(routes: [
            "/": ("text/html", page),
            "/worker.js": ("text/javascript", send("dedicated")),
            "/shared.js": ("text/javascript", "onconnect = () => {}; " + send("shared")),
            "/sw.js": ("text/javascript", "self.addEventListener('install', () => {}); " + send("service")),
        ])
        let base = "http://127.0.0.1:\(site.port)/"
        let inspector = NativeWebInspector(policy: .init(hosts: ["127.0.0.1"], allowLoopbackHTTP: true))
        let (result, _) = try await inspector.inspect(URL(string: base)!, steps: [["wait": 2500], ["read": "#status li"]])
        let statuses = ((result["steps"] as? [[String: Any]])?[1]["text"] as? [String]) ?? []
        let blocked = result["blocked"] as? [String] ?? []
        print("Page statuses: \(statuses)")
        print("Blocked: \(blocked)")
        print("Site requests: \(site.requests)")
        try check(result["title"] as? String == "Worker probe" && statuses.count == 9, "probe page loads and reports every worker attempt")
        let nonGET = site.requests.filter { !$0.hasPrefix("GET ") }
        try check(nonGET.isEmpty, "no worker of any kind sent a non-GET request (saw: \(nonGET))")
        try check(!site.requests.contains { $0.contains("/worker.js") || $0.contains("/shared.js") || $0.contains("/sw.js") }, "no worker script was even fetched")
        for name in ["dedicated", "module", "blob", "data", "shared", "frame-realm", "frame-realm-shared"] {
            try check(statuses.contains(name + ": refused"), name + " worker refused")
        }
        try check(statuses.contains("frame-fetch: refused"), "POST fetch from a fresh frame realm refused")
        try check(statuses.contains("service: refused") || statuses.contains("service: unavailable"), "service worker registration refused")
        try check(blocked.contains { $0.hasPrefix("Worker ") } && blocked.contains { $0.hasPrefix("SharedWorker ") } && blocked.contains { $0.hasPrefix("service worker ") }, "refused workers are reported as blocked actions")

        // Ordinary page GETs still work after the worker guard is in place.
        let plain = try WorkerSite(routes: ["/": ("text/html", "<!doctype html><title>Plain</title><p id='s'>idle</p><script>fetch('/data').then(r => r.status).then(s => document.getElementById('s').textContent = 'got ' + s)</script>"), "/data": ("text/plain", "ok")])
        let (plainResult, _) = try await NativeWebInspector(policy: .init(hosts: ["127.0.0.1"], allowLoopbackHTTP: true)).inspect(URL(string: "http://127.0.0.1:\(plain.port)/")!, steps: [["wait": 500], ["read": "#s"]])
        try check(((plainResult["steps"] as? [[String: Any]])?[1]["text"] as? [String]) == ["got 200"] && plain.requests.contains { $0.hasPrefix("GET /data ") }, "page GET fetches are unaffected")
        print("PASS: \(checks) web inspection worker checks")
    }
}
