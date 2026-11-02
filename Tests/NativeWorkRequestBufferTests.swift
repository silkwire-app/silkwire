import Foundation

@main struct NativeWorkRequestBufferTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { print("FAIL: \(label)"); exit(1) }
            checks += 1
        }
        for marker in ["<<WORK_PROJECT", "<<READ_PROJECT", "<<INSPECT_WEB"] {
            let request = " \n" + marker + " {\"action\":\"read\",\"path\":\"example.swift\"}>>"
            for split in 0...request.count {
                let index = request.index(request.startIndex, offsetBy: split)
                var buffer = NativeWorkRequestBuffer()
                check(buffer.append(String(request[..<index])).isEmpty, "prefix held")
                check(buffer.append(String(request[index...])).isEmpty, "remaining payload held")
                check(buffer.finish(completed: true) == request, "completed request preserved exactly")
                check(buffer.finish(completed: true).isEmpty, "request delivered once")
            }
            var interrupted = NativeWorkRequestBuffer()
            for character in request { check(interrupted.append(String(character)).isEmpty, "single-character fragments stay hidden") }
            check(interrupted.finish(completed: false).isEmpty, "failed request never leaks")
        }
        var overflow = NativeWorkRequestBuffer()
        check(overflow.append("<<WORK_PROJECT {\"content\":\"").isEmpty, "write prefix hidden")
        check(overflow.append(String(repeating: "x", count: 39900)).isEmpty, "large incomplete write hidden before transport limit")
        check(overflow.finish(completed: false).isEmpty, "output-bound failure exposes no partial write")
        var prose = NativeWorkRequestBuffer()
        check(prose.append("Hello ") == "Hello ", "ordinary prose streams immediately")
        check(prose.append("Jason") == "Jason", "later prose streams")
        check(prose.finish(completed: true).isEmpty, "prose not duplicated")
        var falsePrefix = NativeWorkRequestBuffer()
        check(falsePrefix.append("<<W").isEmpty, "ambiguous prefix held")
        check(falsePrefix.append("elcome") == "<<Welcome", "non-broker prefix released unchanged")
        var fresh = NativeWorkRequestBuffer()
        check(fresh.append("New turn") == "New turn", "fresh turn has no stale request")
        print("PASS: \(checks) NativeWorkRequestBuffer checks")
    }
}
