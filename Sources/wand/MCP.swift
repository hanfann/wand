import Foundation

// Minimal MCP stdio server (JSON-RPC 2.0, newline-delimited). Exposes Wand's
// commands as tools so MCP clients (Claude Code, Codex, Cursor, …) can drive the
// simulator. All work goes through the warm daemon, so tool calls are fast.
enum MCP {
    struct Tool {
        let name: String
        let description: String
        let schema: [String: Any]
        let toArgv: ([String: Any]) -> [String]
    }

    static func str(_ a: [String: Any], _ k: String) -> String? { a[k] as? String }
    static func numStr(_ a: [String: Any], _ k: String) -> String? {
        if let d = a[k] as? Double { return String(d) }
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
                 description: "Token-efficient accessibility snapshot of on-screen elements. Each line: ref role \"label\" #id =value @centerX,centerY. diff=true returns only changes since the last snapshot; full=true includes off-screen elements too.",
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
                     return ["tap", numStr(a, "x") ?? "0", numStr(a, "y") ?? "0"]
                 },
            Tool(name: "tapText",
                 description: "Tap visible on-screen text via OCR. Works on ANY app with no accessibility setup (canvas, games, webviews, vibe-coded apps).",
                 schema: obj(["text": pStr], required: ["text"])) { a in ["tapocr", str(a, "text") ?? ""] },
            Tool(name: "see",
                 description: "OCR the screen: every visible text region with tap coordinates. Use when the accessibility tree is sparse or the app has no testIDs.",
                 schema: obj([:])) { _ in ["see"] },
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
                 description: "Type text. If selector is given, the field is tapped first; otherwise types into the focused field.",
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
                     ["swipe", numStr(a, "x1") ?? "0", numStr(a, "y1") ?? "0", numStr(a, "x2") ?? "0", numStr(a, "y2") ?? "0"]
                 },
            Tool(name: "drag",
                 description: "Plain drag from (x1,y1) to (x2,y2).",
                 schema: obj(["x1": pNum, "y1": pNum, "x2": pNum, "y2": pNum], required: ["x1", "y1", "x2", "y2"])) { a in
                     ["drag", numStr(a, "x1") ?? "0", numStr(a, "y1") ?? "0", numStr(a, "x2") ?? "0", numStr(a, "y2") ?? "0"]
                 },
            Tool(name: "dragdrop",
                 description: "Drag-and-drop with long-press pickup. Give fromSelector+toSelector, or x1,y1,x2,y2.",
                 schema: obj(["fromSelector": pStr, "toSelector": pStr, "x1": pNum, "y1": pNum, "x2": pNum, "y2": pNum])) { a in
                     if let f = str(a, "fromSelector"), let t = str(a, "toSelector") { return ["dragdrop", f, t] }
                     return ["dragdrop", numStr(a, "x1") ?? "0", numStr(a, "y1") ?? "0", numStr(a, "x2") ?? "0", numStr(a, "y2") ?? "0"]
                 },
            Tool(name: "longpress",
                 description: "Long-press an element (selector) or point (x,y), optional duration seconds.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum, "seconds": pNum])) { a in
                     if let s = str(a, "selector") { return ["longpress", s] }
                     var v = ["longpress", numStr(a, "x") ?? "0", numStr(a, "y") ?? "0"]
                     if let sec = numStr(a, "seconds") { v.append(sec) }
                     return v
                 },
            Tool(name: "pinch",
                 description: "Pinch an element (selector) or point (x,y). scale>1 zoom in, <1 zoom out.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum, "scale": pNum], required: ["scale"])) { a in
                     if let s = str(a, "selector") { return ["pinch", s, numStr(a, "scale") ?? "1"] }
                     return ["pinch", numStr(a, "x") ?? "0", numStr(a, "y") ?? "0", numStr(a, "scale") ?? "1"]
                 },
            Tool(name: "rotate",
                 description: "Two-finger rotate an element (selector) or point (x,y) by radians.",
                 schema: obj(["selector": pStr, "x": pNum, "y": pNum, "radians": pNum], required: ["radians"])) { a in
                     if let s = str(a, "selector") { return ["rotate", s, numStr(a, "radians") ?? "0"] }
                     return ["rotate", numStr(a, "x") ?? "0", numStr(a, "y") ?? "0", numStr(a, "radians") ?? "0"]
                 },
            Tool(name: "screenshot",
                 description: "Capture a PNG screenshot to an optional path (defaults to ~/.wand/last.png). Use sparingly — prefer ui for token efficiency.",
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

    static func run() {
        let toolList = tools()
        let toolsByName = Dictionary(uniqueKeysWithValues: toolList.map { ($0.name, $0) })

        func send(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  var s = String(data: data, encoding: .utf8) else { return }
            s += "\n"
            FileHandle.standardOutput.write(s.data(using: .utf8)!)
        }
        func result(_ id: Any, _ value: Any) { send(["jsonrpc": "2.0", "id": id, "result": value]) }

        while let line = readLineRaw() {
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]

            switch method {
            case "initialize":
                result(id ?? NSNull(), [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "wand", "version": "0.1.0"],
                ])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "tools/list":
                let arr = toolList.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
                result(id ?? NSNull(), ["tools": arr])
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                guard let tool = toolsByName[name] else {
                    result(id ?? NSNull(), ["content": [["type": "text", "text": "unknown tool \(name)"]], "isError": true])
                    continue
                }
                let udid = Simctl.resolveUDID(nil) ?? ""
                let (ok, text) = udid.isEmpty
                    ? (false, "no booted simulator")
                    : Client.send(udid, tool.toArgv(args))
                result(id ?? NSNull(), ["content": [["type": "text", "text": text]], "isError": !ok])
            default:
                if let id = id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]]) }
            }
        }
    }

    // Read one line from stdin (blocking), nil on EOF.
    private static func readLineRaw() -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(0, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .utf8) }
            if byte == 0x0A { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
    }
}
