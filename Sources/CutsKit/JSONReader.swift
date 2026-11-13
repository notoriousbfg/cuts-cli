import Foundation

/// One problem found in a project file, with the JSON path it was found at.
public struct Issue: Encodable, Equatable {
    public let path: String
    public let message: String
}

/// Thrown when a project cannot be loaded or planned. Carries every problem found, not just the first.
public struct ProjectError: Error, CustomStringConvertible {
    public let issues: [Issue]
    public init(_ issues: [Issue]) { self.issues = issues }
    public init(_ path: String, _ message: String) { issues = [Issue(path: path, message: message)] }
    public var description: String {
        issues.map { $0.path.isEmpty ? $0.message : "\($0.path): \($0.message)" }.joined(separator: "\n")
    }
}

final class Issues {
    private(set) var list: [Issue] = []
    func add(_ path: String, _ message: String) { list.append(Issue(path: path, message: message)) }
    var isEmpty: Bool { list.isEmpty }
}

/// A strict view of a JSON object: typed getters that record problems instead of throwing,
/// and `finish()` to report any key nobody asked for (a typo an agent would otherwise never see).
final class JObj {
    let dict: [String: Any]
    let path: String
    let issues: Issues
    private var used = Set<String>()

    init(_ dict: [String: Any], path: String, issues: Issues) {
        self.dict = dict
        self.path = path
        self.issues = issues
    }

    func sub(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
    func has(_ key: String) -> Bool { dict[key] != nil && !(dict[key] is NSNull) }

    func raw(_ key: String) -> Any? {
        used.insert(key)
        guard let v = dict[key], !(v is NSNull) else { return nil }
        return v
    }

    func str(_ key: String) -> String? {
        guard let v = raw(key) else { return nil }
        if let s = v as? String { return s }
        issues.add(sub(key), "expected a string")
        return nil
    }

    func num(_ key: String) -> Double? {
        guard let v = raw(key) else { return nil }
        if let d = JObj.number(v) { return d }
        issues.add(sub(key), "expected a number")
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let v = raw(key) else { return nil }
        if let n = v as? NSNumber, JObj.isBool(n) { return n.boolValue }
        issues.add(sub(key), "expected true or false")
        return nil
    }

    func obj(_ key: String) -> JObj? {
        guard let v = raw(key) else { return nil }
        if let d = v as? [String: Any] { return JObj(d, path: sub(key), issues: issues) }
        issues.add(sub(key), "expected an object")
        return nil
    }

    func arr(_ key: String) -> [Any]? {
        guard let v = raw(key) else { return nil }
        if let a = v as? [Any] { return a }
        issues.add(sub(key), "expected an array")
        return nil
    }

    func oneOf(_ key: String, _ allowed: [String]) -> String? {
        guard let s = str(key) else { return nil }
        if allowed.contains(s) { return s }
        issues.add(sub(key), "\"\(s)\" is not one of: \(allowed.joined(separator: ", "))")
        return nil
    }

    func finish() {
        for key in dict.keys.sorted() where !used.contains(key) {
            issues.add(sub(key), "unknown key")
        }
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        return n.doubleValue
    }
}

public struct RGBA: Equatable {
    public var r, g, b, a: Double

    public static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    public static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, or `black` / `white` / `transparent`.
    public init?(_ string: String) {
        switch string.lowercased() {
        case "black": self = .black; return
        case "white": self = .white; return
        case "transparent", "clear": self = .clear; return
        default: break
        }
        guard string.hasPrefix("#") else { return nil }
        var hex = String(string.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            self.init(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255, a: 1)
        } else {
            self.init(r: Double((v >> 24) & 255) / 255, g: Double((v >> 16) & 255) / 255,
                      b: Double((v >> 8) & 255) / 255, a: Double(v & 255) / 255)
        }
    }

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// ffmpeg colour syntax.
    var ffmpeg: String {
        String(format: "0x%02X%02X%02X@%.3f", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a)
    }
}
