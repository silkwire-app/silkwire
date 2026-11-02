import Foundation
import AppKit
import WebKit

/// Brokered web inspection for agents, with a screenshot preview for Jason.
/// Ephemeral session: no cookies, sign-ins or site data persist or are reused.
/// Main-frame navigation is limited to approved hosts (or one private workspace
/// folder, with all network blocked), and the page cannot submit forms or send
/// non-GET requests, so an inspection cannot send an inquiry or change an account.
@MainActor final class NativeWebInspector: NSObject, WKNavigationDelegate {
    nonisolated static let approvedHosts: Set<String> = ["staging.silkwire.si", "staging.silkwire.app"]
    struct Policy {
        var hosts: Set<String> = NativeWebInspector.approvedHosts
        /// Synthetic tests only: plain HTTP to 127.0.0.1 hosts in `hosts`.
        var allowLoopbackHTTP = false
        /// Private workspace preview: file URLs inside this folder, no network at all.
        var fileRoot: URL?
    }
    nonisolated static let viewports: [String: CGSize] = ["desktop": CGSize(width: 1280, height: 800), "mobile": CGSize(width: 390, height: 844)]

    private let policy: Policy
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadWaiter: CheckedContinuation<Void, Error>?
    private var mainStatus: Int?
    private var blocked: [String] = []
    private var navigations = 0
    private var redirects: [String] = []
    /// A main-frame load is in flight; cleared by finish/fail callbacks.
    private var pendingLoad = false
    init(policy: Policy) { self.policy = policy }

    nonisolated static func validate(_ text: String, policy: Policy) throws -> URL {
        guard text.utf8.count <= 2048, let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else { throw nativeFailure("Use a complete approved https URL.") }
        guard let host = url.host?.lowercased(), policy.hosts.contains(host) else { throw nativeFailure("Only these sites can be inspected: \(policy.hosts.sorted().joined(separator: ", ")).") }
        if scheme == "https", url.port == nil || url.port == 443 { return url }
        if scheme == "http", policy.allowLoopbackHTTP, host == "127.0.0.1" { return url }
        throw nativeFailure("Use https on the default port for approved sites.")
    }
    nonisolated static func stillRetryURL(requested: URL, final: URL, policy: Policy) -> URL? {
        guard let item = URLComponents(url: requested, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "still" }),
              (try? validate(final.absoluteString, policy: policy)) != nil,
              var components = URLComponents(url: final, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "still" }) != true else { return nil }
        components.queryItems = (components.queryItems ?? []) + [item]
        return components.url
    }
    private func permitted(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        if let root = policy.fileRoot {
            guard url.isFileURL else { return false }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path, base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path == base || path.hasPrefix(base + "/")
        }
        return (try? Self.validate(url.absoluteString, policy: policy)) != nil
    }

    // Runs before any page script, in every frame: refuses form submission, non-GET
    // requests, beacons, WebSockets and workers, and records console/page errors.
    nonisolated static let guardScript = """
    (() => {
      const blocked = window.__silkwireBlocked = [];
      const errors = window.__silkwireErrors = [];
      const note = (what) => { if (blocked.length < 40) blocked.push(String(what).slice(0, 300)); };
      document.addEventListener('submit', (e) => { e.preventDefault(); e.stopImmediatePropagation(); note('form submit to ' + (e.target && e.target.action || 'page')); }, true);
      HTMLFormElement.prototype.submit = function () { note('form.submit() to ' + (this.action || 'page')); };
      HTMLFormElement.prototype.requestSubmit = function () { note('form.requestSubmit() to ' + (this.action || 'page')); };
      const fetchOriginal = window.fetch;
      window.fetch = function (input, init) {
        const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        if (method !== 'GET' && method !== 'HEAD') { note(method + ' fetch ' + String(input && input.url || input)); return Promise.reject(new TypeError('Blocked by Silkwire inspection: ' + method)); }
        return fetchOriginal.apply(this, arguments);
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__silkwireMethod = String(method).toUpperCase(); this.__silkwireURL = url; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () { if (this.__silkwireMethod && this.__silkwireMethod !== 'GET' && this.__silkwireMethod !== 'HEAD') { note(this.__silkwireMethod + ' XHR ' + this.__silkwireURL); this.abort(); return; } return send.apply(this, arguments); };
      if (navigator.sendBeacon) navigator.sendBeacon = function (url) { note('beacon ' + url); return false; };
      window.WebSocket = function (url) { note('WebSocket ' + url); throw new Error('Blocked by Silkwire inspection'); };
      // Worker realms never receive this guard, so no worker of any kind may start.
      const refuse = (owner, name, label) => { if (owner && name in owner) Object.defineProperty(owner, name, { configurable: false, writable: false, value: function (url) { note(label + ' ' + url); throw new TypeError('Blocked by Silkwire inspection: ' + label); } }); };
      refuse(window, 'Worker', 'Worker'); refuse(window, 'SharedWorker', 'SharedWorker');
      if (window.ServiceWorkerContainer) Object.defineProperty(ServiceWorkerContainer.prototype, 'register', { configurable: false, writable: false, value: function (url) { note('service worker ' + url); return Promise.reject(new TypeError('Blocked by Silkwire inspection: service worker')); } });
      window.addEventListener('error', (e) => { if (errors.length < 20) errors.push(String(e.message || e.type).slice(0, 300)); });
      window.addEventListener('unhandledrejection', (e) => { if (errors.length < 20) errors.push('unhandled rejection: ' + String(e.reason).slice(0, 300)); });
      const consoleError = console.error;
      console.error = function () { if (errors.length < 20) errors.push(Array.from(arguments).map(String).join(' ').slice(0, 300)); return consoleError.apply(this, arguments); };
    })();
    """

    /// Loads `url` (or a workspace file), performs up to 12 steps, and returns page
    /// text, links, step results, errors, blocked attempts and a PNG screenshot.
    func inspect(_ url: URL, steps: [[String: Any]], viewport: String = "desktop") async throws -> (result: [String: Any], screenshot: Data?) {
        guard steps.count <= 12 else { throw nativeFailure("Use at most 12 steps per inspection.") }
        guard let size = Self.viewports[viewport] else { throw nativeFailure("Viewport is desktop or mobile.") }
        guard permitted(url) else { throw nativeFailure(policy.fileRoot == nil ? "Only approved sites can be inspected." : "Preview a file inside your workspace.") }
        blocked = []; redirects = []; navigations = 0; mainStatus = nil
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The host window is offscreen; without this WebKit suspends timers/animation
        // there and the screenshot shows only the page's first frame.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.addUserScript(WKUserScript(source: Self.guardScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if policy.fileRoot != nil {
            // Workspace previews are fully offline: no http(s) or socket loads at all.
            // WebKit's rule regex subset has no disjunction: one rule per scheme.
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
            // Fail closed: without the blocking rules there is no offline guarantee.
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "silkwire-offline-preview-v1", encodedContentRuleList: rules) else { throw nativeFailure("Offline preview rules could not be prepared; nothing was rendered.") }
            configuration.userContentController.add(list)
        }
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        view.navigationDelegate = self
        // Rendering for a snapshot needs a window; it is never shown on screen.
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.contentView = view
        // An ordered offscreen window gives WebKit a backing surface for composited
        // content. Merely assigning contentView can produce a black snapshot.
        host.backgroundColor = .windowBackgroundColor; host.orderFront(nil)
        webView = view; window = host
        defer { view.stopLoading(); view.navigationDelegate = nil; host.contentView = nil; host.close(); webView = nil; window = nil }
        let started = Date()
        pendingLoad = true
        if let root = policy.fileRoot { view.loadFileURL(url, allowingReadAccessTo: root) } else { view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) }
        try await waitForLoad(seconds: 20)
        // Some approved aliases discard ?still in their redirect. Re-request the
        // approved final URL once with the explicitly requested still parameter.
        // This is a new GET after the prior navigation completed, not a relaxation
        // of the redirect/host boundary and not an infinite redirect rewrite.
        var stillRetry: URL?
        if policy.fileRoot == nil, let final = view.url, let retry = Self.stillRetryURL(requested: url, final: final, policy: policy) {
            stillRetry = retry; pendingLoad = true
            view.load(URLRequest(url: retry, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            try await waitForLoad(seconds: 20)
        }
        var results: [[String: Any]] = []
        for (index, step) in steps.enumerated() {
            var outcome: [String: Any] = ["step": index + 1]
            do { outcome.merge(try await perform(step, in: view)) { _, new in new }; outcome["ok"] = outcome["ok"] ?? true }
            catch { outcome["ok"] = false; outcome["error"] = error.localizedDescription }
            results.append(outcome)
        }
        let readiness = try? await view.callAsyncJavaScript("""
            await Promise.race([Promise.all([document.fonts ? document.fonts.ready : Promise.resolve(),
              ...Array.from(document.images).map(i => i.complete ? Promise.resolve() : new Promise(r => { i.addEventListener('load', r, {once:true}); i.addEventListener('error', r, {once:true}); }))]), new Promise(r => setTimeout(r, 1500))]);
            await Promise.race([new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))), new Promise(r => setTimeout(r, 500))]);
            return {readyState: document.readyState, images: document.images.length, pendingImages: Array.from(document.images).filter(i => !i.complete).length};
            """, arguments: [:], in: nil, contentWorld: .page)
        let page = try await evaluate("""
            (() => ({ title: document.title, url: location.href,
              text: (document.body ? document.body.innerText : '').slice(0, 16000),
              textLength: (document.body ? document.body.innerText : '').length,
              links: Array.from(document.querySelectorAll('a[href]')).slice(0, 40).map(a => ({ text: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 120), href: a.href })),
              errors: window.__silkwireErrors || [], blocked: window.__silkwireBlocked || [] }))()
            """, in: view) as? [String: Any] ?? [:]
        let snapshot = WKSnapshotConfiguration(); snapshot.rect = NSRect(origin: .zero, size: size); snapshot.afterScreenUpdates = true; snapshot.snapshotWidth = NSNumber(value: Double(size.width))
        var captureError: String?
        var png: Data?
        var dark = false
        for attempt in 0..<2 {
            do {
                let image = try await view.takeSnapshot(configuration: snapshot)
                png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
                dark = png.map(Self.isUniformDark) ?? false
                if !dark { break }
                if attempt == 0 { try await Task.sleep(for: .milliseconds(350)) }
            } catch { captureError = error.localizedDescription; break }
        }
        var result: [String: Any] = ["requestedURL": url.absoluteString, "finalURL": page["url"] ?? view.url?.absoluteString ?? "", "title": page["title"] ?? "", "viewport": viewport,
                                     "text": page["text"] ?? "", "textShortened": (page["textLength"] as? Int ?? 0) > 16000, "links": page["links"] ?? [], "steps": results,
                                     "consoleErrors": page["errors"] ?? [], "blocked": blocked + (page["blocked"] as? [String] ?? []), "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10, "untrusted": true]
        if let stillRetry { result["stillModeRetryURL"] = stillRetry.absoluteString }
        result["redirects"] = redirects
        result["captureReadiness"] = readiness ?? NSNull()
        var warnings: [String] = []
        if dark { warnings.append("Image is nearly uniform dark after retry; the visual result is unverified.") }
        if let captureError { warnings.append("Snapshot failed: " + captureError) }
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "still" }) == true,
           view.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems?.contains(where: { $0.name == "still" }) != true { warnings.append("The final URL lost the requested still parameter during navigation.") }
        if let bytes = png, bytes.count > 2 * 1024 * 1024 {
            png = Self.previewPNG(bytes)
            if png == nil { warnings.append("Capture exceeded the inline image budget and could not be reduced.") }
        }
        result["captureWarnings"] = warnings
        if let mainStatus { result["httpStatus"] = mainStatus }
        if let png { result["screenshotSha256"] = NativeScopedRoot.sha256(png); result["screenshotSize"] = "\(Int(size.width))x\(Int(size.height))" } else { result["screenshot"] = "unavailable" }
        return (result, png)
    }
    private func perform(_ step: [String: Any], in view: WKWebView) async throws -> [String: Any] {
        let quote: (String) throws -> String = { try nativeJSON($0) }
        if let selector = step["click"] as? String, step.count == 1 {
            let before = navigations
            let value = try await evaluate("(() => { const el = document.querySelector(\(try quote(selector))); if (!el) return { ok: false, error: 'No element matches the selector.' }; el.scrollIntoView({block: 'center'}); el.click(); return { ok: true, clicked: el.tagName.toLowerCase(), label: (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 120) }; })()", in: view) as? [String: Any] ?? [:]
            try await settle(after: before)
            return value
        }
        if let selector = step["type"] as? String, let text = step["text"] as? String, step.count == 2 {
            guard text.utf16.count <= 2000 else { throw nativeFailure("Type at most 2,000 characters.") }
            return try await evaluate("(() => { const el = document.querySelector(\(try quote(selector))); if (!el) return { ok: false, error: 'No element matches the selector.' }; if ((el.type || '').toLowerCase() === 'password') return { ok: false, error: 'Password fields are never filled.' }; el.focus(); el.value = \(try quote(text)); el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return { ok: true, typed: el.value.length }; })()", in: view) as? [String: Any] ?? [:]
        }
        if let ms = step["wait"] as? Int, step.count == 1 {
            guard (0...5000).contains(ms) else { throw nativeFailure("Wait 0–5000 ms.") }
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000); return ["ok": true, "waitedMs": ms]
        }
        if let y = step["scroll"] as? Int, step.count == 1 {
            _ = try await evaluate("window.scrollTo(0, \(max(0, y))); 0", in: view); return ["ok": true, "scrolledTo": max(0, y)]
        }
        if let selector = step["read"] as? String, step.count == 1 {
            return try await evaluate("(() => { const items = Array.from(document.querySelectorAll(\(try quote(selector)))).slice(0, 10); return { ok: items.length > 0, matches: items.length, text: items.map(el => (el.innerText || el.value || '').trim().slice(0, 2000)) }; })()", in: view) as? [String: Any] ?? [:]
        }
        throw nativeFailure("Each step is one of {\"click\":css}, {\"type\":css,\"text\":...}, {\"wait\":ms}, {\"scroll\":y} or {\"read\":css}.")
    }
    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: nativeFailure("Page script failed: " + error.localizedDescription)) } else { continuation.resume(returning: value) }
            }
        }
    }
    /// After a click: if it started a navigation, wait for it; then let the page settle.
    private func settle(after before: Int) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        if navigations != before || pendingLoad { try? await waitForLoad(seconds: 15) }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    private func waitForLoad(seconds: Double) async throws {
        guard pendingLoad else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadWaiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self, let waiter = self.loadWaiter else { return }
                self.loadWaiter = nil; waiter.resume(throwing: nativeFailure("The page did not finish loading within \(Int(seconds)) seconds."))
            }
        }
    }
    private func finishLoad(_ error: Error? = nil) {
        pendingLoad = false
        guard let waiter = loadWaiter else { return }; loadWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let method = action.request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET", ![.formSubmitted, .formResubmitted].contains(action.navigationType) else { blocked.append("\(method) navigation to \(action.request.url?.absoluteString ?? "?")"); return .cancel }
        if action.targetFrame?.isMainFrame != false {
            guard permitted(action.request.url) else { blocked.append("navigation outside approved sites: \(action.request.url?.absoluteString ?? "?")"); return .cancel }
            navigations += 1; pendingLoad = true
        }
        return .allow
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame {
            guard permitted(response.response.url) else { blocked.append("response outside approved sites: " + (response.response.url?.absoluteString ?? "?")); finishLoad(nativeFailure("Redirect reached an unapproved site.")); return .cancel }
            if let http = response.response as? HTTPURLResponse { mainStatus = http.statusCode }
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url { redirects.append(url.absoluteString) }
    }
    static func previewPNG(_ data: Data) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        for width in [1280, 960, 640] {
            let height = max(1, Int(Double(width) * source.size.height / max(1, source.size.width)))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            source.draw(in: NSRect(x: 0, y: 0, width: width, height: height)); context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
            if let bytes = bitmap.representation(using: .png, properties: [:]), bytes.count <= 2 * 1024 * 1024 { return bytes }
        }
        return nil
    }
    nonisolated static func isUniformDark(_ data: Data) -> Bool {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16)); return true
        }
        guard rendered else { return false }
        let brightness = stride(from: 0, to: pixels.count, by: 4).map { max(pixels[$0], max(pixels[$0 + 1], pixels[$0 + 2])) }
        return brightness.filter { $0 < 18 }.count >= 252
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(nativeFailure("Page load failed: " + error.localizedDescription)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A cancelled (blocked) navigation is reported in `blocked`, not as a load failure.
        if (error as NSError).code == NSURLErrorCancelled || (error as NSError).code == 102 { finishLoad(); return }
        finishLoad(nativeFailure("Page could not be reached: " + error.localizedDescription))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishLoad(nativeFailure("The page's web process ended unexpectedly.")) }
}
