import Foundation

// Pure, dependency-free screen model — lives in its own library target so it can
// be unit-tested without a simulator.

/// A single accessibility element, normalized from the engine's dictionary.
public struct UIElement {
    public let ref: String
    public let role: String
    public let label: String?
    public let id: String?
    public let value: String?
    public let x: Double, y: Double, w: Double, h: Double
    public let enabled: Bool
    public let depth: Int
    public var onScreen: Bool = true

    public var cx: Int { Int((x + w / 2).rounded()) }
    public var cy: Int { Int((y + h / 2).rounded()) }

    /// Short role without the "AX" prefix.
    public var shortRole: String { role.hasPrefix("AX") ? String(role.dropFirst(2)) : role }

    /// Stable identity for diffing across snapshots.
    public var key: String { (id.map { "#\($0)" }) ?? "\(role)|\(label ?? "")" }
}

/// A token-efficient view of the screen: only meaningful/interactable elements,
/// each on one compact line with a stable ref and tap-ready center coordinates.
public struct Snapshot {
    public let all: [UIElement]
    public let byRef: [String: UIElement]
    public let screenW: Double
    public let screenH: Double

    public static let interactableRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField", "AXSwitch",
        "AXSlider", "AXLink", "AXCheckBox", "AXMenuItem", "AXTabButton",
        "AXSearchField", "AXCell", "AXImage", "AXPopUpButton", "AXSegmentedControl",
        "AXToggle", "AXStepper", "AXTab",
    ]

    /// Decide if an element carries information worth showing an agent.
    public static func interesting(role: String, label: String?, id: String?, value: String?, w: Double, h: Double) -> Bool {
        if w <= 0 || h <= 0 { return false }
        if let id = id, !id.isEmpty { return true }
        if interactableRoles.contains(role) { return true }
        if let l = label, !l.isEmpty { return true }
        if let v = value, !v.isEmpty { return true }
        return false
    }

    public init(elements: [[String: Any]], screenW: Double = 0, screenH: Double = 0) {
        self.screenW = screenW
        self.screenH = screenH
        var kept: [UIElement] = []
        var map: [String: UIElement] = [:]
        var n = 0
        for e in elements {
            let role = (e["role"] as? String) ?? ""
            let label = (e["label"] as? String)?.nilIfEmpty
            let id = (e["id"] as? String)?.nilIfEmpty
            let value = (e["value"] as? String)?.nilIfEmpty
            let w = (e["w"] as? Double) ?? 0
            let h = (e["h"] as? Double) ?? 0
            guard Snapshot.interesting(role: role, label: label, id: id, value: value, w: w, h: h) else { continue }
            n += 1
            let x = (e["x"] as? Double) ?? 0
            let y = (e["y"] as? Double) ?? 0
            guard [x, y, w, h].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else { continue }
            // On-screen if the rect intersects the viewport (with a small margin).
            let onScreen = screenW <= 0 || screenH <= 0
                || (x + w > -1 && x < screenW + 1 && y + h > -1 && y < screenH + 1)
            let el = UIElement(
                ref: "e\(n)", role: role, label: label, id: id, value: value,
                x: x, y: y, w: w, h: h,
                enabled: (e["enabled"] as? Bool) ?? true,
                depth: (e["depth"] as? Int) ?? 0,
                onScreen: onScreen
            )
            kept.append(el)
            map[el.ref] = el
        }
        self.all = kept
        self.byRef = map
    }

    public func line(_ e: UIElement) -> String {
        var s = "\(e.ref) \(e.shortRole)"
        if let l = e.label { s += " \"\(l)\"" }
        if let i = e.id { s += " #\(i)" }
        if let v = e.value { s += " =\(v)" }
        s += " @\(e.cx),\(e.cy)"
        if !e.enabled { s += " (disabled)" }
        return s
    }

    public var compact: String { all.map(line).joined(separator: "\n") }
    public var visible: [UIElement] { all.filter { $0.onScreen } }
    public var compactVisible: String { visible.map(line).joined(separator: "\n") }

    /// Resolve a selector to an element:
    ///   eN          -> by ref
    ///   #identifier -> by accessibility id (exact, then contains)
    ///   text        -> by label/value (exact, then contains), case-insensitive
    /// Prefers on-screen, top-most matches.
    public func resolve(_ selector: String) -> UIElement? {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty, sel != "#" else { return nil }
        if sel.hasPrefix("e"), Int(sel.dropFirst()) != nil { return byRef[sel] }
        func pick(_ pred: (UIElement) -> Bool) -> UIElement? {
            all.filter { pred($0) && $0.onScreen }.min(by: { $0.y < $1.y })
                ?? all.first(where: pred)
        }
        if sel.hasPrefix("#") {
            let want = String(sel.dropFirst())
            return pick { $0.id == want } ?? pick { ($0.id ?? "").localizedCaseInsensitiveContains(want) }
        }
        let lower = sel.lowercased()
        return pick { ($0.label?.lowercased() == lower) || ($0.value?.lowercased() == lower) }
            ?? pick { ($0.label?.lowercased().contains(lower) ?? false) || ($0.value?.lowercased().contains(lower) ?? false) }
    }

    public func find(_ query: String) -> [UIElement] {
        let q = query.lowercased()
        return all.filter {
            ($0.label?.lowercased().contains(q) ?? false)
            || ($0.id?.lowercased().contains(q) ?? false)
            || ($0.value?.lowercased().contains(q) ?? false)
            || $0.shortRole.lowercased().contains(q)
        }
    }

    /// Input cannot safely choose the first of several matches, a disabled
    /// control, or a center outside the viewport. Observation stays permissive.
    public func resolveForInput(_ selector: String, requiresVisibleCenter: Bool = true) throws -> UIElement? {
        let sel = selector.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty, sel != "#" else { return nil }
        var candidates: [UIElement]
        if sel.hasPrefix("e"), Int(sel.dropFirst()) != nil {
            candidates = byRef[sel].map { [$0] } ?? []
        } else if sel.hasPrefix("#") {
            let id = String(sel.dropFirst())
            candidates = all.filter { $0.id == id }
            if candidates.isEmpty { candidates = all.filter { $0.id?.localizedCaseInsensitiveContains(id) == true } }
        } else {
            let text = sel.lowercased()
            candidates = all.filter { $0.label?.lowercased() == text || $0.value?.lowercased() == text }
            if candidates.isEmpty {
                candidates = all.filter { $0.label?.lowercased().contains(text) == true || $0.value?.lowercased().contains(text) == true }
            }
        }
        let visible = candidates.filter(\.onScreen)
        if !visible.isEmpty { candidates = visible }
        guard candidates.count <= 1 else { throw TargetError.ambiguous }
        guard let element = candidates.first else { return nil }
        guard element.enabled else { throw TargetError.disabled }
        if requiresVisibleCenter {
            guard element.onScreen, element.cx >= 0, element.cy >= 0,
                  screenW <= 0 || Double(element.cx) < screenW,
                  screenH <= 0 || Double(element.cy) < screenH else { throw TargetError.offscreen }
        }
        return element
    }

    public enum TargetError: String, LocalizedError {
        case ambiguous = "ambiguous accessibility target; use a fresh eN reference or unique identifier"
        case disabled = "accessibility target is disabled; no input sent"
        case offscreen = "accessibility target center is off-screen; scroll into view before input"
        public var errorDescription: String? { rawValue }
    }

    /// Token-saving diff: what changed vs a previous snapshot, keyed by identity.
    public func diff(from prev: Snapshot) -> String {
        // Occurrence-qualified identities preserve repeated labels/IDs instead
        // of collapsing a list of identical controls into one dictionary entry.
        func keyed(_ elements: [UIElement]) -> [(String, UIElement)] {
            var counts: [String: Int] = [:]
            return elements.map { element in
                let index = counts[element.key, default: 0]
                counts[element.key] = index + 1
                return ("\(element.key)|occurrence:\(index)", element)
            }
        }
        let old = keyed(prev.all), current = keyed(all)
        let prevByKey = Dictionary(uniqueKeysWithValues: old)
        let curByKey = Dictionary(uniqueKeysWithValues: current)
        var lines: [String] = []
        for (key, e) in current where prevByKey[key] == nil { lines.append("+ \(line(e))") }
        for (key, e) in old where curByKey[key] == nil { lines.append("- \(prev.line(e))") }
        for (key, e) in current {
            if let p = prevByKey[key], p.value != e.value || p.label != e.label
                || p.ref != e.ref || p.role != e.role || p.enabled != e.enabled
                || p.onScreen != e.onScreen || p.x != e.x || p.y != e.y || p.w != e.w || p.h != e.h {
                lines.append("~ \(line(e))")
            }
        }
        return lines.isEmpty ? "(no change)" : lines.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
