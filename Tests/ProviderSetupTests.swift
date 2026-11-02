import Foundation
import Darwin

@main struct ProviderSetupTests {
    @MainActor static func main() async throws {
        var checks = 0
        func verify(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-signin-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let mock = base.appendingPathComponent("provider.py")
        try #"""
#!/usr/bin/python3
import json,os,sys,time
mode=open('mode').read()
def emit(v):
 print(json.dumps(v),flush=True)
def record(v):
 with open('methods','a') as f: f.write(v+'\n')
if len(sys.argv)>1 and sys.argv[1]=='auth':
 record(' '.join(sys.argv[1:]))
 if sys.argv[2]=='status':
  signed=mode=='existing' or os.path.exists('signed')
  emit({'loggedIn':signed,'authMethod':'api-key' if mode=='api' else 'claude.ai'})
  sys.exit(0)
 if mode=='timeout': time.sleep(30)
 if mode=='failed':
  print('private-diagnostic https://example.invalid/token=private')
  sys.exit(1)
 open('signed','w').write('yes')
 sys.exit(0)
for line in sys.stdin:
 event=json.loads(line); method=event.get('method'); record(method)
 if 'id' not in event: continue
 result={}
 if method=='account/read':
  signed=mode=='existing' or os.path.exists('signed')
  result={'account':{'type':'apiKey' if mode=='api' else 'chatgpt'} if signed else None}
 if method=='account/login/start':
  result={'type':'chatgpt','authUrl':'https://attacker.invalid/login' if mode=='evil' else 'https://auth.openai.com/oauth/authorize?state=synthetic','loginId':'synthetic-id'}
 if method=='account/login/cancel': result={}
 emit({'id':event['id'],'result':result})
 if method=='account/login/start' and mode not in ['timeout','evil','cancel']:
  if mode not in ['failed','wrongid','api']: open('signed','w').write('yes')
  emit({'method':'account/login/completed','params':{'loginId':'unrelated-id' if mode=='wrongid' else 'synthetic-id','success':mode!='failed','error':'private-diagnostic'}})
"""#.write(to: mock, atomically: true, encoding: .utf8)
        chmod(mock.path, 0o700)
        func folder(_ mode: String) throws -> URL {
            let root = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            return root
        }
        func methods(_ root: URL) -> String { (try? String(contentsOf: root.appendingPathComponent("methods"), encoding: .utf8)) ?? "" }
        func wait(_ predicate: () -> Bool) async {
            for _ in 0..<500 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
            preconditionFailure("Sign-in fixture did not settle")
        }
        for url in ["http://auth.openai.com/login", "https://auth.openai.com.evil.test/login", "https://evil.test/", "file:///tmp/auth", "https://x@auth.openai.com/login", "https://auth.openai.com:444/login", "https://auth.openai.com/login#token", "javascript:alert(1)"] {
            verify(NativeProviderSetup.validatedOpenAIURL(url) == nil, "reject untrusted OAuth URL")
        }
        verify(NativeProviderSetup.validatedOpenAIURL("https://auth.openai.com/oauth/authorize?state=synthetic") != nil, "OpenAI authorization host allowed")
        verify(NativeProviderSetup.validatedOpenAIURL("https://chatgpt.com:443/") != nil, "ChatGPT HTTPS allowed")
        verify(NativeProviderSetup.validatedOpenAIURL("https://auth.openai.com/?" + String(repeating: "a", count: 17000)) == nil, "OAuth URL bounded")
        for provider in ["codex", "claude"] {
            let root = try folder("existing"); var browser = 0, completed = 0
            let setup = NativeProviderSetup(codex: mock.path, claude: mock.path, directory: root, loginTimeout: 0.4, openBrowser: { _ in browser += 1; return true })
            verify(methods(root).isEmpty && setup.agent == nil, "constructing setup never starts auth")
            setup.signIn(provider) { completed += 1 }
            await wait { setup.agent == nil }
            verify(completed == 1 && browser == 0, "existing account reused without browser")
            verify(!methods(root).contains("login"), "existing account never logged out or in again")
        }
        for provider in ["codex", "claude"] {
            let root = try folder("good"); var browser = 0, completed = 0
            let setup = NativeProviderSetup(codex: mock.path, claude: mock.path, directory: root, loginTimeout: 0.4, openBrowser: { _ in browser += 1; return true })
            setup.signIn(provider) { completed += 1 }; await wait { setup.agent == nil }
            verify(completed == 1, "managed login confirms actual subscription account")
            verify(provider == "claude" || browser == 1, "Codex browser opened explicitly")
            let log = methods(root)
            verify(provider == "codex" ? log.hasPrefix("initialize\ninitialized\naccount/read\naccount/login/start\n") : log.contains("auth login --claudeai"), "official protocol/arguments used")
            verify(!log.contains("turn/") && !log.contains("thread/") && !log.contains("logout"), "sign-in creates no chat or resets")
        }
        for mode in ["evil", "failed", "wrongid", "api", "timeout"] {
            let root = try folder(mode); var browser = 0, completed = 0
            let setup = NativeProviderSetup(codex: mock.path, directory: root, loginTimeout: 0.25, openBrowser: { _ in browser += 1; return true })
            setup.signIn("codex") { completed += 1 }; await wait { setup.agent == nil }
            verify(completed == 0, "failed, unrelated, missing or API auth never succeeds")
            verify(!setup.message.contains("private-diagnostic") && !setup.message.contains("https:"), "no private auth output exposed")
            if mode == "evil" { verify(browser == 0 && methods(root).contains("account/login/cancel"), "untrusted URL never opened and pending login cancelled") }
            if mode == "timeout" { verify(methods(root).contains("account/login/cancel"), "expired managed login cancelled") }
        }
        do {
            let root = try folder("good"); var completed = 0
            let setup = NativeProviderSetup(codex: mock.path, directory: root, loginTimeout: 0.2, openBrowser: { _ in false })
            setup.signIn("codex") { completed += 1 }; await wait { setup.agent == nil }
            verify(completed == 0 && methods(root).contains("account/login/cancel"), "browser launch failure cancels provider login")
        }
        for provider in ["codex", "claude"] {
            let root = try folder(provider == "codex" ? "cancel" : "timeout"); var completed = 0
            let setup = NativeProviderSetup(codex: mock.path, claude: mock.path, directory: root, loginTimeout: 30, openBrowser: { _ in true })
            setup.signIn(provider) { completed += 1 }
            await wait { methods(root).contains(provider == "codex" ? "account/login/start" : "auth login") }
            setup.cancel()
            if provider == "codex" { await wait { methods(root).contains("account/login/cancel") } }
            try? await Task.sleep(nanoseconds: 200_000_000)
            verify(setup.agent == nil && completed == 0 && setup.message.contains("cancelled"), "cancel fences stale completion and stops owned auth")
        }
        for mode in ["failed", "api", "timeout"] {
            let root = try folder(mode); var completed = 0
            let setup = NativeProviderSetup(claude: mock.path, directory: root, loginTimeout: 0.1, openBrowser: { _ in true })
            setup.signIn("claude") { completed += 1 }; await wait { setup.agent == nil }
            verify(completed == 0 && !setup.message.contains("private-diagnostic"), "Claude failure/API/timeout fail closed with private output suppressed")
        }
        NativeProcess.shutdownOwnedGroups()
        print("PASS: \(checks) provider setup checks; mock official tools and browser only, no real credentials or account changes")
    }
}
