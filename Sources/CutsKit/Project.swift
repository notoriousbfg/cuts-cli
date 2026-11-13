import Foundation

// MARK: - Model

public enum Fill: Equatable {
    case color(RGBA)
    case gradient(RGBA, RGBA, angle: Double)
}

/// A time on the timeline: seconds, or another clip's edge plus an offset (`"intro.end-0.5"`).
public enum TimeExpr: Equatable {
    case seconds(Double)
    case ref(clip: String, edge: Edge, offset: Double)
    public enum Edge: String { case start, end }

    /// Reads `<clip id>.start` or `<clip id>.end`, with an optional `+N` or `-N` after it.
    public static func reference(_ text: String) -> TimeExpr? {
        let body = text.replacingOccurrences(of: " ", with: "")
        guard let match = body.wholeMatch(of: #/(.+)\.(start|end)([+-][0-9]*\.?[0-9]+)?/#),
              let edge = Edge(rawValue: String(match.2)) else { return nil }
        return .ref(clip: String(match.1), edge: edge, offset: match.3.flatMap { Double($0) } ?? 0)
    }
}

public struct Transition: Equatable {
    public var type: String      // an ffmpeg xfade transition name
    public var duration: Double
}

public struct ShadowSpec: Equatable {
    public var blur: Double
    public var x: Double
    public var y: Double
    public var color: RGBA
}

public struct TextStyle: Equatable {
    public var font: String?
    public var fontFile: String?
    public var size: Double = 64
    public var weight: String = "regular"
    public var italic = false
    public var color: RGBA = .white
    public var tracking: Double = 0
    public var lineHeight: Double = 1.15
}

public struct TextLine: Equatable {
    public var text: String
    public var style: TextStyle
    public var gap: Double   // extra space above this line, px
}

public struct TextBox: Equatable {
    public var color: RGBA
    public var padding: Double
    public var radius: Double
}

public struct TextSpec: Equatable {
    public var lines: [TextLine]
    public var align: String        // left | center | right
    public var maxWidth: Double     // fraction of the canvas width
    public var box: TextBox?
    public var background: Fill?
}

public enum Fit: String { case contain, cover, stretch, none }

public struct Clip {
    public enum Kind {
        case media(path: String)   // video, image or audio file
        case fill(Fill)
        case text(TextSpec)
    }

    public var id: String
    public var path: String        // JSON path, for error messages
    public var kind: Kind
    public var start: TimeExpr?
    public var end: TimeExpr?
    public var sourceIn: Double?
    public var sourceOut: Double?
    public var duration: Double?
    public var speed: Double = 1
    public var transition: Transition?
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    public var fit: Fit = .contain
    public var scale: Double = 1
    public var position: (x: Double, y: Double) = (0.5, 0.5)
    public var anchor: (x: Double, y: Double) = (0.5, 0.5)
    public var opacity: Double = 1
    public var crop: (x: Double, y: Double, w: Double, h: Double)?
    public var radius: Double = 0
    public var shadow: ShadowSpec?
    public var volume: Double = 1
    public var mute = false
}

public struct Track {
    public var id: String
    public var enabled = true
    public var volume: Double = 1
    public var clips: [Clip]
}

public struct Output {
    public var path: String?
    public var width = 1920
    public var height = 1080
    public var fps: Double = 30
    public var background: Fill = .color(.black)
    public var codec = "h264"
    public var crf: Int?
}

public struct Project {
    public var output: Output
    public var tracks: [Track]
    /// Folder the project file is in; relative paths resolve against it.
    public var baseDir: URL

    public func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return baseDir.appendingPathComponent(expanded).standardizedFileURL.path
    }
}

public let xfadeTransitions: [String] = [
    "fade", "fadeblack", "fadewhite", "fadegrays", "fadefast", "fadeslow", "dissolve", "pixelize", "distance",
    "wipeleft", "wiperight", "wipeup", "wipedown", "wipetl", "wipetr", "wipebl", "wipebr",
    "slideleft", "slideright", "slideup", "slidedown",
    "smoothleft", "smoothright", "smoothup", "smoothdown",
    "coverleft", "coverright", "coverup", "coverdown",
    "revealleft", "revealright", "revealup", "revealdown",
    "circlecrop", "rectcrop", "circleopen", "circleclose", "radial",
    "vertopen", "vertclose", "horzopen", "horzclose",
    "diagtl", "diagtr", "diagbl", "diagbr",
    "hlslice", "hrslice", "vuslice", "vdslice", "hlwind", "hrwind", "vuwind", "vdwind",
    "hblur", "squeezeh", "squeezev", "zoomin",
]

let transitionAliases: [String: String] = [
    "crossfade": "fade", "cross-fade": "fade", "dip-to-black": "fadeblack", "dip-to-white": "fadewhite",
    "zoom": "zoomin", "blur": "hblur",
]

// MARK: - Loading

extension Project {
    public static func load(path: String) throws -> Project {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ProjectError("", "cannot read \(url.path)")
        }
        return try parse(data: data, baseDir: url.deletingLastPathComponent())
    }

    public static func parse(data: Data, baseDir: URL) throws -> Project {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch {
            throw ProjectError("", "not valid JSON: \(error.localizedDescription)")
        }
        guard let dict = json as? [String: Any] else { throw ProjectError("", "the project must be a JSON object") }
        let issues = Issues()
        let root = JObj(dict, path: "", issues: issues)
        _ = root.raw("$schema"); _ = root.raw("name"); _ = root.raw("notes")
        if let v = root.num("version"), v != 1 { issues.add("version", "only version 1 is supported") }

        var output = Output()
        if let o = root.obj("output") {
            output.path = o.str("path")
            if let w = o.num("width") { output.width = Int(w) }
            if let h = o.num("height") { output.height = Int(h) }
            if let f = o.num("fps") { output.fps = f }
            if let raw = o.raw("background") { output.background = parseFill(raw, o.sub("background"), issues) ?? output.background }
            if let c = o.oneOf("codec", ["h264", "hevc"]) { output.codec = c }
            if let c = o.num("crf") { output.crf = Int(c) }
            if output.width < 16 || output.height < 16 || output.width % 2 != 0 || output.height % 2 != 0 {
                issues.add("output", "width and height must be even numbers of at least 16")
            }
            if output.fps <= 0 || output.fps > 240 { issues.add("output.fps", "must be between 1 and 240") }
            o.finish()
        }

        var media: [String: String] = [:]
        if let m = root.obj("media") {
            for key in m.dict.keys { if let p = m.str(key) { media[key] = p } }
        }

        var styles: [String: [String: Any]] = [:]
        if let s = root.obj("styles") {
            for key in s.dict.keys { if let d = s.obj(key) { styles[key] = d.dict } }
        }

        var tracks: [Track] = []
        var seen = Set<String>()
        let rawTracks = root.arr("tracks") ?? []
        if !root.has("tracks") { issues.add("tracks", "a project needs a \"tracks\" array") }
        for (ti, rawTrack) in rawTracks.enumerated() {
            let tpath = "tracks[\(ti)]"
            guard let td = rawTrack as? [String: Any] else { issues.add(tpath, "expected an object"); continue }
            let t = JObj(td, path: tpath, issues: issues)
            var track = Track(id: t.str("id") ?? "track\(ti + 1)", clips: [])
            track.enabled = t.bool("enabled") ?? true
            track.volume = t.num("volume") ?? 1
            _ = t.raw("notes")
            for (ci, rawClip) in (t.arr("clips") ?? []).enumerated() {
                let cpath = "\(tpath).clips[\(ci)]"
                guard var cd = rawClip as? [String: Any] else { issues.add(cpath, "expected an object"); continue }
                if let name = cd["style"] as? String {
                    if let style = styles[name] {
                        cd = style.merging(cd) { _, own in own }
                    } else {
                        issues.add("\(cpath).style", "no style named \"\(name)\" in \"styles\"")
                    }
                }
                let c = JObj(cd, path: cpath, issues: issues)
                if let clip = parseClip(c, defaultID: "\(track.id).\(ci + 1)", media: media, issues: issues) {
                    if !seen.insert(clip.id).inserted { issues.add("\(cpath).id", "duplicate clip id \"\(clip.id)\"") }
                    track.clips.append(clip)
                }
            }
            t.finish()
            tracks.append(track)
        }
        root.finish()
        if !issues.isEmpty { throw ProjectError(issues.list) }
        return Project(output: output, tracks: tracks, baseDir: baseDir)
    }

    static func parseClip(_ c: JObj, defaultID: String, media: [String: String], issues: Issues) -> Clip? {
        _ = c.raw("style"); _ = c.raw("notes")
        let kinds = ["src", "fill", "text"].filter { c.has($0) }
        guard kinds.count == 1 else {
            issues.add(c.path, "a clip needs exactly one of \"src\", \"fill\" or \"text\"")
            return nil
        }
        let kind: Clip.Kind
        switch kinds[0] {
        case "src":
            let s = c.str("src") ?? ""
            kind = .media(path: media[s] ?? s)
        case "fill":
            guard let f = parseFill(c.raw("fill")!, c.sub("fill"), issues) else { return nil }
            kind = .fill(f)
        default:
            guard let t = parseText(c, issues) else { return nil }
            kind = .text(t)
        }

        var clip = Clip(id: c.str("id") ?? defaultID, path: c.path, kind: kind)
        if clip.id.contains(where: { $0.isWhitespace || $0 == "+" }) && c.has("id") {
            issues.add(c.sub("id"), "ids cannot contain spaces or +")
        }
        clip.start = c.raw("start").flatMap { parseTime($0, c.sub("start"), issues) }
        clip.end = c.raw("end").flatMap { parseTime($0, c.sub("end"), issues) }
        clip.sourceIn = c.num("in")
        clip.sourceOut = c.num("out")
        clip.duration = c.num("duration")
        clip.speed = c.num("speed") ?? 1
        if clip.speed < 0.1 || clip.speed > 20 { issues.add(c.sub("speed"), "must be between 0.1 and 20") }
        if let d = clip.duration, d <= 0 { issues.add(c.sub("duration"), "must be more than 0") }
        if clip.duration != nil && clip.end != nil { issues.add(c.sub("end"), "give \"duration\" or \"end\", not both") }
        if case .media = kind {} else {
            for key in ["in", "out", "speed"] where c.has(key) {
                issues.add(c.sub(key), "only applies to clips with \"src\"")
            }
        }

        if let raw = c.raw("transition") {
            var type: String?
            var duration = 0.5
            if let s = raw as? String {
                type = s
            } else if let d = raw as? [String: Any] {
                let t = JObj(d, path: c.sub("transition"), issues: issues)
                type = t.str("type")
                duration = t.num("duration") ?? 0.5
                t.finish()
            } else {
                issues.add(c.sub("transition"), "expected a transition name or {\"type\", \"duration\"}")
            }
            if let given = type, given != "cut", given != "none" {
                let name = transitionAliases[given] ?? given.replacingOccurrences(of: "-", with: "")
                if !xfadeTransitions.contains(name) {
                    issues.add(c.sub("transition"), "unknown transition \"\(given)\" (run `cuts transitions` for the list)")
                } else if duration <= 0 {
                    issues.add(c.sub("transition"), "duration must be more than 0")
                } else {
                    clip.transition = Transition(type: name, duration: duration)
                }
            }
        }

        clip.fadeIn = max(0, c.num("fadeIn") ?? 0)
        clip.fadeOut = max(0, c.num("fadeOut") ?? 0)
        if let f = c.oneOf("fit", ["contain", "cover", "stretch", "none"]) { clip.fit = Fit(rawValue: f)! }
        clip.scale = c.num("scale") ?? 1
        if clip.scale <= 0 { issues.add(c.sub("scale"), "must be more than 0") }
        if let p = parsePoint(c, "position", issues) { clip.position = p }
        if let a = parsePoint(c, "anchor", issues) { clip.anchor = a }
        clip.opacity = min(1, max(0, c.num("opacity") ?? 1))
        if let r = c.arr("crop") {
            let n = r.compactMap(JObj.number)
            if n.count == 4, n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0, n[0] + n[2] <= 1.0001, n[1] + n[3] <= 1.0001 {
                clip.crop = (n[0], n[1], n[2], n[3])
            } else {
                issues.add(c.sub("crop"), "expected [x, y, width, height] as fractions of the source (0–1)")
            }
        }
        clip.radius = max(0, c.num("radius") ?? 0)
        if let raw = c.raw("shadow") {
            let isText: Bool
            if case .text = kind { isText = true } else { isText = false }
            var s = isText
                ? ShadowSpec(blur: 12, x: 0, y: 3, color: RGBA(r: 0, g: 0, b: 0, a: 0.5))
                : ShadowSpec(blur: 48, x: 0, y: 18, color: RGBA(r: 0, g: 0, b: 0, a: 0.35))
            if let on = raw as? NSNumber, JObj.isBool(on) {
                clip.shadow = on.boolValue ? s : nil
            } else if let d = raw as? [String: Any] {
                let o = JObj(d, path: c.sub("shadow"), issues: issues)
                s.blur = max(0, o.num("blur") ?? s.blur)
                s.x = o.num("x") ?? s.x
                s.y = o.num("y") ?? s.y
                if let col = o.str("color") {
                    if let rgba = RGBA(col) { s.color = rgba } else { issues.add(o.sub("color"), "not a colour") }
                }
                if let op = o.num("opacity") { s.color.a = min(1, max(0, op)) }
                o.finish()
                clip.shadow = s
            } else {
                issues.add(c.sub("shadow"), "expected true or {\"blur\", \"x\", \"y\", \"color\", \"opacity\"}")
            }
        }
        clip.volume = max(0, c.num("volume") ?? 1)
        clip.mute = c.bool("mute") ?? false
        c.finish()
        return clip
    }

    static func parsePoint(_ c: JObj, _ key: String, _ issues: Issues) -> (x: Double, y: Double)? {
        guard let raw = c.raw(key) else { return nil }
        if let a = raw as? [Any] {
            let n = a.compactMap(JObj.number)
            if n.count == 2 { return (n[0], n[1]) }
        } else if let s = raw as? String {
            let named: [String: (Double, Double)] = [
                "center": (0.5, 0.5), "top": (0.5, 0), "bottom": (0.5, 1), "left": (0, 0.5), "right": (1, 0.5),
                "top-left": (0, 0), "top-right": (1, 0), "bottom-left": (0, 1), "bottom-right": (1, 1),
            ]
            if let p = named[s] { return (p.0, p.1) }
        }
        issues.add(c.sub(key), "expected [x, y] (0–1) or a name such as \"center\" or \"bottom-left\"")
        return nil
    }

    static func parseTime(_ raw: Any, _ path: String, _ issues: Issues) -> TimeExpr? {
        if let d = JObj.number(raw) {
            if d < 0 { issues.add(path, "cannot be negative"); return nil }
            return .seconds(d)
        }
        if let s = raw as? String {
            if let ref = TimeExpr.reference(s) { return ref }
        }
        issues.add(path, "expected seconds or a reference such as \"intro.end-0.5\"")
        return nil
    }

    static func parseFill(_ raw: Any, _ path: String, _ issues: Issues) -> Fill? {
        func color(_ v: Any, _ p: String) -> RGBA? {
            if let s = v as? String, let c = RGBA(s) { return c }
            issues.add(p, "expected a colour such as \"#1c1c1e\" or \"#000000cc\"")
            return nil
        }
        if raw is String { return color(raw, path).map(Fill.color) }
        var stops: [Any]?
        var angle = 90.0
        if let a = raw as? [Any] {
            stops = a
        } else if let d = raw as? [String: Any] {
            let o = JObj(d, path: path, issues: issues)
            stops = o.arr("gradient")
            angle = o.num("angle") ?? 90
            o.finish()
        }
        guard let s = stops, s.count == 2 else {
            issues.add(path, "expected a colour, [from, to], or {\"gradient\": [from, to], \"angle\": degrees}")
            return nil
        }
        guard let a = color(s[0], "\(path)[0]"), let b = color(s[1], "\(path)[1]") else { return nil }
        return .gradient(a, b, angle: angle)
    }

    static let weights = ["ultralight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]

    static func parseStyle(_ o: JObj, base: TextStyle, _ issues: Issues) -> TextStyle {
        var s = base
        if let f = o.str("font") { s.font = f; s.fontFile = nil }
        if let f = o.str("fontFile") { s.fontFile = f }
        if let v = o.num("size") { s.size = v }
        if let w = o.oneOf("weight", weights) { s.weight = w }
        if let i = o.bool("italic") { s.italic = i }
        if let c = o.str("color") {
            if let rgba = RGBA(c) { s.color = rgba } else { issues.add(o.sub("color"), "not a colour") }
        }
        if let t = o.num("tracking") { s.tracking = t }
        if let l = o.num("lineHeight") { s.lineHeight = l }
        if s.size <= 0 { issues.add(o.sub("size"), "must be more than 0") }
        return s
    }

    static func parseText(_ c: JObj, _ issues: Issues) -> TextSpec? {
        let base = parseStyle(c, base: TextStyle(), issues)
        var lines: [TextLine] = []
        let raw = c.raw("text")!
        if let s = raw as? String {
            lines = [TextLine(text: s, style: base, gap: 0)]
        } else if let a = raw as? [Any] {
            for (i, item) in a.enumerated() {
                let p = "\(c.sub("text"))[\(i)]"
                if let s = item as? String {
                    lines.append(TextLine(text: s, style: base, gap: 0))
                } else if let d = item as? [String: Any] {
                    let o = JObj(d, path: p, issues: issues)
                    let style = parseStyle(o, base: base, issues)
                    lines.append(TextLine(text: o.str("text") ?? "", style: style, gap: o.num("gap") ?? 0))
                    o.finish()
                } else {
                    issues.add(p, "expected a string or {\"text\", …style}")
                }
            }
        } else {
            issues.add(c.sub("text"), "expected a string or an array of lines")
        }
        guard !lines.isEmpty else { issues.add(c.sub("text"), "no text"); return nil }

        var spec = TextSpec(lines: lines, align: "center", maxWidth: 0.84, box: nil, background: nil)
        if let a = c.oneOf("align", ["left", "center", "right"]) { spec.align = a }
        if let m = c.num("maxWidth") { spec.maxWidth = min(1, max(0.05, m)) }
        if let b = c.obj("box") {
            var box = TextBox(color: RGBA(r: 0, g: 0, b: 0, a: 0.6), padding: b.num("padding") ?? 24, radius: b.num("radius") ?? 12)
            if let col = b.str("color") {
                if let rgba = RGBA(col) { box.color = rgba } else { issues.add(b.sub("color"), "not a colour") }
            }
            b.finish()
            spec.box = box
        }
        if let raw = c.raw("background") { spec.background = parseFill(raw, c.sub("background"), issues) }
        return spec
    }
}
