import Foundation
import CoreFoundation
import WandKit

// Minimal MCP stdio server (JSON-RPC 2.0, newline-delimited). Exposes Wand's
// commands as tools so MCP clients (Claude Code, Codex, Cursor, …) can drive the
// simulator. All work goes through the warm daemon, so tool calls are fast.
enum MCP {
    struct Tool: @unchecked Sendable {
        let name: String
        let description: String
        let schema: [String: Any]
        let toArgv: ([String: Any]) -> [String]
    }

    static func str(_ a: [String: Any], _ k: String) -> String? { a[k] as? String }
    static func numStr(_ a: [String: Any], _ k: String) -> String? {
        if let d = a[k] as? Double {
            guard d.isFinite else { return nil }
            return d.rounded() == d && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }
        if let i = a[k] as? Int { return String(i) }
        if let s = a[k] as? String { return s }
        return nil
    }

    static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    static var pStr: [String: Any] { ["type": "string"] }
    static var pNum: [String: Any] { ["type": "number"] }

    static func tools() -> [Tool] {
        [
            Tool(name: "ui",
                 description: "Compact accessibility snapshot (watch AX may expose only the app). Each line: ref role \"label\" #id =value @centerX,centerY. diff=true returns only changes since the last snapshot; full=true includes off-screen elements too.",
                 schema: obj(["diff": ["type": "boolean"], "full": ["type": "boolean"]])) { a in
                     if a["full"] as? Bool == true { return ["ui", "full"] }
                     return (a["diff"] as? Bool == true) ? ["ui", "diff"] : ["ui"]
                 },
            Tool(name: "scrollTo",
                 description: "Scroll the screen until an element (eN/#id/\"label\") is visible, then stop. Use before tapping something below the fold.",
                 schema: obj(["selector": pStr], required: ["selector"])) { a in ["scrollto", str(a, "selector") ?? ""] },
            Tool(name: "clear",
                 description: "Clear a text field's contents by selector.",
                 schema: obj(["selector": pStr], required: ["selector"])) { a in ["clear", str(a, "selector") ?? ""] },
            Tool(name: "find",
                 description: "Find elements whose label/id/value/role contains the query. Returns matching refs.",
                 schema: obj(["query": pStr], required: ["query"])) { a in ["find", str(a, "query") ?? ""] },
            Tool(name: "tap",
                 description: "Tap an element by selector (eN ref, #identifier, or \"label\") or x/y point. If the selector isn't in the accessibility tree, falls back to tapping visible text via OCR.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum])) { a in
                     if let s = str(a, "selector") { return ["tap", s] }
                     guard let x = numStr(a, "x"), let y = numStr(a, "y") else { return ["tap"] }
                     return ["tap", x, y]
                 },
            Tool(name: "tapText",
                 description: "Tap visible text with bounded OCR. Recognition of custom/pixel fonts is not guaranteed; use screenshot coordinates when needed.",
                 schema: obj(["text": pStr], required: ["text"])) { a in ["tapocr", str(a, "text") ?? ""] },
            Tool(name: "see",
                 description: "Bounded OCR with point coordinates. Optional query filters output. A timeout leaves input usable; use screenshot coordinates if recognition fails.",
                 schema: obj(["query": pStr, "accurate": ["type": "boolean"]])) { a in
                     var args = ["see"]
                     if a["accurate"] as? Bool == true { args.append("accurate") }
                     if let query = str(a, "query") { args.append(query) }
                     return args
                 },
            Tool(name: "setValue",
                 description: "Set a field's value directly (any unicode incl. emoji) by selector — faster/more robust than typing.",
                 schema: obj(["selector": pStr, "text": pStr], required: ["selector", "text"])) { a in
                     ["setvalue", str(a, "selector") ?? "", str(a, "text") ?? ""]
                 },
            Tool(name: "install",
                 description: "Install a .app bundle on the simulator.",
                 schema: obj(["path": pStr], required: ["path"])) { a in ["install", str(a, "path") ?? ""] },
            Tool(name: "launch",
                 description: "Launch an installed app by bundle id.",
                 schema: obj(["bundleId": pStr], required: ["bundleId"])) { a in ["launch", str(a, "bundleId") ?? ""] },
            Tool(name: "terminate",
                 description: "Terminate a running app by bundle id.",
                 schema: obj(["bundleId": pStr], required: ["bundleId"])) { a in ["terminate", str(a, "bundleId") ?? ""] },
            Tool(name: "apps",
                 description: "List installed user app bundle ids.",
                 schema: obj([:])) { _ in ["apps"] },
            Tool(name: "logs",
                 description: "Recent app console logs (last N seconds; defaults to the launched app). Use to see why something failed.",
                 schema: obj(["bundleId": pStr, "seconds": pNum])) { a in
                     var v = ["logs"]
                     if let b = str(a, "bundleId") { v.append(b) }
                     if let s = numStr(a, "seconds") { v.append(s) }
                     return v
                 },
            Tool(name: "crashes",
                 description: "Newest crash report for the app (if any), with the crash header.",
                 schema: obj(["bundleId": pStr])) { a in str(a, "bundleId").map { ["crashes", $0] } ?? ["crashes"] },
            Tool(name: "open",
                 description: "Open a URL / deep link / universal link on the simulator.",
                 schema: obj(["url": pStr], required: ["url"])) { a in ["open", str(a, "url") ?? ""] },
            Tool(name: "type",
                 description: "Type US ASCII with HID; use setValue for Unicode. If selector is given, the field is tapped first; otherwise types into the focused field.",
                 schema: obj(["selector": pStr, "text": pStr], required: ["text"])) { a in
                     if let s = str(a, "selector") { return ["typein", s, str(a, "text") ?? ""] }
                     return ["type", str(a, "text") ?? ""]
                 },
            Tool(name: "key",
                 description: "Press a single HID usage key (e.g. 42=backspace, 40=return).",
                 schema: obj(["usage": pNum], required: ["usage"])) { a in ["key", numStr(a, "usage") ?? "0"] },
            Tool(name: "swipe",
                 description: "Swipe/scroll from (x1,y1) to (x2,y2).",
                 schema: obj(["x1": pNum, "y1": pNum, "x2": pNum, "y2": pNum], required: ["x1", "y1", "x2", "y2"])) { a in
                     ["swipe", numStr(a, "x1") ?? "nan", numStr(a, "y1") ?? "nan", numStr(a, "x2") ?? "nan", numStr(a, "y2") ?? "nan"]
                 },
            Tool(name: "drag",
                 description: "Plain drag from (x1,y1) to (x2,y2).",
                 schema: obj(["x1": pNum, "y1": pNum, "x2": pNum, "y2": pNum], required: ["x1", "y1", "x2", "y2"])) { a in
                     ["drag", numStr(a, "x1") ?? "nan", numStr(a, "y1") ?? "nan", numStr(a, "x2") ?? "nan", numStr(a, "y2") ?? "nan"]
                 },
            Tool(name: "dragdrop",
                 description: "Drag-and-drop with long-press pickup. Give fromSelector+toSelector, or x1,y1,x2,y2.",
                 schema: obj(["fromSelector": pStr, "toSelector": pStr, "x1": pNum, "y1": pNum, "x2": pNum, "y2": pNum])) { a in
                     if let f = str(a, "fromSelector"), let t = str(a, "toSelector") { return ["dragdrop", f, t] }
                     return ["dragdrop", numStr(a, "x1") ?? "nan", numStr(a, "y1") ?? "nan", numStr(a, "x2") ?? "nan", numStr(a, "y2") ?? "nan"]
                 },
            Tool(name: "longpress",
                 description: "Long-press an element (selector) or point (x,y), optional duration seconds.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum, "seconds": pNum])) { a in
                     if let s = str(a, "selector") {
                         return ["longpress", s] + (numStr(a, "seconds").map { [$0] } ?? [])
                     }
                     var v = ["longpress", numStr(a, "x") ?? "nan", numStr(a, "y") ?? "nan"]
                     if let sec = numStr(a, "seconds") { v.append(sec) }
                     return v
                 },
            Tool(name: "pinch",
                 description: "Pinch an element (selector) or point (x,y). scale>1 zoom in, <1 zoom out.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum, "scale": pNum], required: ["scale"])) { a in
                     if let s = str(a, "selector") { return ["pinch", s, numStr(a, "scale") ?? "1"] }
                     return ["pinch", numStr(a, "x") ?? "nan", numStr(a, "y") ?? "nan", numStr(a, "scale") ?? "1"]
                 },
            Tool(name: "rotate",
                 description: "Two-finger rotate an element (selector) or point (x,y) by radians.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum, "radians": pNum], required: ["radians"])) { a in
                     if let s = str(a, "selector") { return ["rotate", s, numStr(a, "radians") ?? "0"] }
                     return ["rotate", numStr(a, "x") ?? "nan", numStr(a, "y") ?? "nan", numStr(a, "radians") ?? "0"]
                 },
            Tool(name: "screenshot",
                 description: "Save a PNG (default ~/.wand/last.png). Prefer text observations when useful; sparse watch AX may need screenshots. Divide pixels by info scale before tapping.",
                 schema: obj(["path": pStr])) { a in str(a, "path").map { ["screenshot", $0] } ?? ["screenshot"] },
            Tool(name: "assert",
                 description: "Assert an element's state: cond is exists | gone | value=… | label=…. Returns PASS/FAIL.",
                 schema: obj(["selector": pStr, "cond": pStr], required: ["selector"])) { a in
                     var v = ["assert", str(a, "selector") ?? ""]
                     if let c = str(a, "cond") { v.append(c) }
                     return v
                 },
            Tool(name: "wait",
                 description: "Poll until a selector appears, up to timeoutMs (default 5000).",
                 schema: obj(["selector": pStr, "timeoutMs": pNum], required: ["selector"])) { a in
                     var v = ["wait", str(a, "selector") ?? ""]
                     if let t = numStr(a, "timeoutMs") { v.append(t) }
                     return v
                 },
            Tool(name: "info",
                 description: "Booted simulator info (name, udid, screen size).",
                 schema: obj([:])) { _ in ["info"] },
        ]
    }

    static func run(compact: Bool = false, defaultUDID: String? = nil) {
        let runTool = Tool(name: "run",
            description: "Run ordered Wand commands on an explicit simulator. Coordinates are points. Stops at first error; inspect before retrying. summary=true returns count and final result or failed step; end with ui diff/assert/screenshot to verify. See wand help or skill.",
            schema: obj(["udid": pStr, "summary": ["type": "boolean"], "commands": ["type": "array", "minItems": 1, "maxItems": 64,
                "items": ["type": "array", "minItems": 1, "items": pStr]]], required: ["commands"])) { args in
                guard let commands = args["commands"] as? [[String]],
                      let data = try? JSONSerialization.data(withJSONObject: commands) else { return ["batch", "null"] }
                return ["batch"] + (args["summary"] as? Bool == true ? ["--summary"] : [])
                    + [String(decoding: data, as: UTF8.self)]
            }
        let toolList = compact ? [runTool] : tools()
        let toolsByName = Dictionary(uniqueKeysWithValues: toolList.map { ($0.name, $0) })

        let session = Session()
        let work = DispatchQueue(label: "wand.mcp.commands")
        let reader = LineReader(fd: STDIN_FILENO)
        while let line = reader.next() {
            guard let data = line.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                session.error(NSNull(), -32700, "parse error"); continue
            }
            guard let msg = value as? [String: Any], msg["jsonrpc"] as? String == "2.0",
                  let method = msg["method"] as? String,
                  msg["id"] == nil || Session.key(msg["id"]!) != nil else {
                session.error(NSNull(), -32600, "invalid request"); continue
            }
            let id = msg["id"]
            if method == "notifications/cancelled" {
                if id == nil, let params = msg["params"] as? [String: Any], let target = params["requestId"] {
                    session.cancel(target)
                }
                continue
            }
            // JSON-RPC notifications never produce replies or simulator input.
            guard let id else { continue }
            switch method {
            case "initialize":
                session.result(id, ["protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "wand", "version": "0.1.0"]])
            case "ping":
                session.result(id, [String: Any]())
            case "tools/list":
                let arr = toolList.map { tool -> [String: Any] in
                    var schema = tool.schema
                    var props = schema["properties"] as? [String: Any] ?? [:]
                    props["udid"] = pStr; schema["properties"] = props
                    return ["name": tool.name, "description": tool.description, "inputSchema": schema]
                }
                session.result(id, ["tools": arr])
            case "tools/call":
                guard let token = session.register(id) else {
                    session.error(id, -32600, "duplicate active request id or 64-request queue limit reached"); continue
                }
                // Keep stdin responsive to cancellation while serializing simulator work.
                // Capture the wire string rather than crossing queues with mutable Any values.
                work.async {
                    autoreleasepool {
                        let request = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                        let requestID = request["id"]!
                        defer { session.remove(requestID) }
                        guard !token.isCancelled else { return }
                        let value = execute(request["params"], tools: toolsByName,
                                            defaultUDID: defaultUDID, cancellation: token)
                        // MCP cancellation is fire-and-forget. Already-applied input cannot be undone.
                        if !token.isCancelled { session.result(requestID, value) }
                    }
                }
            default:
                session.error(id, -32601, "method not found")
            }
        }
        // EOF is also used by piped CLI clients; complete their queued requests.
        work.sync {}
    }

    private static func execute(_ params: Any?, tools: [String: Tool], defaultUDID: String?,
                                cancellation: CommandCancellation) -> [String: Any] {
        func output(_ ok: Bool, _ text: String) -> [String: Any] {
            ["content": [["type": "text", "text": text]], "isError": !ok]
        }
        guard let params = params as? [String: Any], let name = params["name"] as? String,
              let tool = tools[name] else { return output(false, "unknown or missing tool") }
        if let arguments = params["arguments"], !(arguments is [String: Any]) {
            return output(false, "arguments must be an object")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let required = tool.schema["required"] as? [String] ?? []
        let properties = tool.schema["properties"] as? [String: [String: Any]] ?? [:]
        let invalidTarget = args["udid"].map { !($0 is String) || ($0 as? String)?.isEmpty == true } ?? false
        let invalid = invalidTarget || required.contains { args[$0] == nil } || args.contains { key, value in
            switch properties[key]?["type"] as? String {
            case "number": return !(value is NSNumber) || CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
            case "string": return !(value is String)
            case "boolean": return CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()
            default: return false
            }
        }
        if invalid { return output(false, "invalid or missing tool arguments") }
        let command = tool.toArgv(args)
        do { try CommandValidation.validate(command) }
        catch { return output(false, error.localizedDescription) }
        if cancellation.isCancelled { return output(false, "cancelled before dispatch") }
        guard let udid = Simctl.resolveUDID(str(args, "udid") ?? defaultUDID) else {
            return output(false, "no unique simulator; pass udid or set WAND_UDID")
        }
        let (ok, text) = Client.send(udid, command, cancellation: cancellation)
        return output(ok, text)
    }

    private final class Session: @unchecked Sendable {
        private let lock = NSLock(), outputLock = NSLock()
        private var requests: [String: CommandCancellation] = [:]
        static func key(_ id: Any) -> String? {
            guard id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()),
                  let data = try? JSONSerialization.data(withJSONObject: [id], options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        func register(_ id: Any) -> CommandCancellation? {
            guard let key = Self.key(id) else { return nil }
            lock.lock(); defer { lock.unlock() }
            guard requests[key] == nil, requests.count < 64 else { return nil }
            let token = CommandCancellation(); requests[key] = token; return token
        }
        func remove(_ id: Any) {
            guard let key = Self.key(id) else { return }
            lock.lock(); defer { lock.unlock() }; requests.removeValue(forKey: key)
        }
        func cancel(_ id: Any) {
            guard let key = Self.key(id) else { return }
            lock.lock(); let token = requests[key]; lock.unlock(); token?.cancel()
        }
        func result(_ id: Any, _ value: Any) { send(["jsonrpc": "2.0", "id": id, "result": value]) }
        func error(_ id: Any, _ code: Int, _ message: String) {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }
        private func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(10)
            outputLock.lock(); defer { outputLock.unlock() }
            FileHandle.standardOutput.write(data)
        }
    }
}
