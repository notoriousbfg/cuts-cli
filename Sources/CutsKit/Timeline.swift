import Foundation

/// A clip with its place on the timeline worked out, in whole output frames.
public struct PlannedClip {
    public let clip: Clip
    public var info: MediaInfo?
    public var startF = 0
    public var durF = 0
    public var sourceIn = 0.0
    /// Frames of the transition into this clip; 0 for a cut.
    public var transitionF = 0
    /// The transition comes in over empty track (the layers below) rather than over the previous clip.
    public var transitionFromGap = false
    /// Frames of the next clip's transition that overlap this clip's tail.
    public var outgoingF = 0

    public var endF: Int { startF + durF }
    public var hasVideo: Bool {
        if case .media = clip.kind { return info?.hasVideo ?? false }
        return true
    }
    public var hasAudio: Bool {
        if case .media = clip.kind { return (info?.hasAudio ?? false) && !(info?.isImage ?? false) && !clip.mute && clip.volume > 0 }
        return false
    }
}

public struct Plan {
    public let project: Project
    public let fps: Double
    public let totalF: Int
    public let tracks: [[PlannedClip]]
    public let warnings: [String]

    public var duration: Double { Double(totalF) / fps }
    public func seconds(_ frames: Int) -> Double { (Double(frames) / fps * 1000).rounded() / 1000 }
}

public enum Planner {
    public static func make(_ project: Project, probe: (String) throws -> MediaInfo = Tools.probe) throws -> Plan {
        let issues = Issues()
        var warnings: [String] = []
        let fps = project.output.fps
        func frames(_ seconds: Double) -> Int { Int((seconds * fps).rounded()) }

        // Probe every source once.
        var infos: [String: MediaInfo] = [:]
        var failed = Set<String>()
        var tracks: [[PlannedClip]] = project.tracks.map { track in
            track.clips.map { clip in
                var planned = PlannedClip(clip: clip)
                if case .media(let raw) = clip.kind {
                    let path = project.resolve(raw)
                    if infos[path] == nil && !failed.contains(path) {
                        do { infos[path] = try probe(path) } catch {
                            failed.insert(path)
                            issues.add("\(clip.path).src", "\(error)")
                        }
                    }
                    planned.info = infos[path]
                    if let info = planned.info, !info.hasVideo, !info.hasAudio {
                        issues.add("\(clip.path).src", "no video or audio in \(path)")
                    }
                }
                return planned
            }
        }

        var index: [String: (Int, Int)] = [:]
        for (t, track) in tracks.enumerated() {
            for (c, planned) in track.enumerated() { index[planned.clip.id] = (t, c) }
        }

        // Length each clip has before any "end" reference is applied.
        func ownFrames(_ p: PlannedClip) -> Int {
            let clip = p.clip
            if case .media = clip.kind, let info = p.info, !info.isImage {
                let start = clip.sourceIn ?? 0
                let end = clip.sourceOut ?? info.duration
                if start < 0 || start >= info.duration {
                    issues.add("\(clip.path).in", "outside the source, which is \(fmt(info.duration)) s long")
                } else if end > info.duration + 0.05 {
                    issues.add("\(clip.path).out", "past the end of the source, which is \(fmt(info.duration)) s long")
                } else if end <= start {
                    issues.add("\(clip.path).out", "must be after \"in\"")
                }
                let natural = max(0, min(end, info.duration) - start) / clip.speed
                if let d = clip.duration, d > natural + 1 / fps, info.hasVideo {
                    warnings.append("\(clip.id): asks for \(fmt(d)) s but the source gives \(fmt(natural)) s; the last frame is held")
                }
                return max(1, frames(clip.duration ?? natural))
            }
            return max(1, frames(clip.duration ?? 4))
        }

        enum State { case visiting, done(Int) }
        var starts: [String: State] = [:]
        var lengths: [String: State] = [:]

        func edge(_ expr: TimeExpr, _ path: String) -> Int {
            switch expr {
            case .seconds(let s):
                return frames(s)
            case .ref(let id, let edge, let offset):
                guard let (t, c) = index[id] else {
                    issues.add(path, "no clip has the id \"\(id)\"")
                    return 0
                }
                let base = edge == .start ? start(t, c) : start(t, c) + length(t, c)
                return base + frames(offset)
            }
        }

        func start(_ t: Int, _ c: Int) -> Int {
            let p = tracks[t][c]
            switch starts[p.clip.id] {
            case .done(let f): return f
            case .visiting:
                issues.add("\(p.clip.path).start", "depends on itself through its references")
                return 0
            case nil: break
            }
            starts[p.clip.id] = .visiting
            var value: Int
            if let expr = p.clip.start {
                value = edge(expr, "\(p.clip.path).start")
                if value < 0 {
                    issues.add("\(p.clip.path).start", "works out to before the start of the timeline")
                    value = 0
                }
            } else if c == 0 {
                value = 0
            } else {
                let overlap = p.clip.transition.map { frames($0.duration) } ?? 0
                value = max(0, start(t, c - 1) + length(t, c - 1) - overlap)
            }
            starts[p.clip.id] = .done(value)
            return value
        }

        func length(_ t: Int, _ c: Int) -> Int {
            let p = tracks[t][c]
            switch lengths[p.clip.id] {
            case .done(let f): return f
            case .visiting:
                issues.add("\(p.clip.path).end", "depends on itself through its references")
                return 1
            case nil: break
            }
            lengths[p.clip.id] = .visiting
            var value = ownFrames(p)
            if let expr = p.clip.end {
                value = edge(expr, "\(p.clip.path).end") - start(t, c)
                if value <= 0 {
                    issues.add("\(p.clip.path).end", "is not after the clip's start")
                    value = 1
                }
            }
            lengths[p.clip.id] = .done(value)
            return value
        }

        for t in tracks.indices {
            for c in tracks[t].indices {
                tracks[t][c].startF = start(t, c)
                tracks[t][c].durF = length(t, c)
                tracks[t][c].sourceIn = tracks[t][c].clip.sourceIn ?? 0
                tracks[t][c].transitionF = tracks[t][c].clip.transition.map { max(1, frames($0.duration)) } ?? 0
            }
        }

        // A track is a single lane: clips may only overlap by exactly their transition.
        if issues.isEmpty {
            for t in tracks.indices {
                for c in tracks[t].indices {
                    let cur = tracks[t][c]
                    let path = cur.clip.path
                    if cur.transitionF > cur.durF {
                        issues.add("\(path).transition", "is longer than the clip (\(fmt(Double(cur.durF) / fps)) s)")
                    }
                    guard c > 0 else {
                        tracks[t][c].transitionFromGap = cur.transitionF > 0
                        continue
                    }
                    let prev = tracks[t][c - 1]
                    let overlap = prev.endF - cur.startF
                    if cur.transitionF > 0 {
                        if overlap == cur.transitionF {
                            tracks[t][c - 1].outgoingF = cur.transitionF
                            let incoming = prev.transitionFromGap ? 0 : prev.transitionF
                            if incoming + cur.transitionF > prev.durF {
                                issues.add("\(path).transition", "the previous clip (\"\(prev.clip.id)\") is too short to hold the transitions on both its ends")
                            }
                        } else if overlap <= 0 {
                            tracks[t][c].transitionFromGap = true
                        } else {
                            issues.add("\(path).start", "overlaps \"\(prev.clip.id)\" by \(fmt(Double(overlap) / fps)) s, but its transition lasts \(fmt(Double(cur.transitionF) / fps)) s; the two must match (leave \"start\" out to have it placed for you)")
                        }
                    } else if overlap > 0 {
                        issues.add("\(path).start", "overlaps \"\(prev.clip.id)\" by \(fmt(Double(overlap) / fps)) s; clips on one track cannot overlap without a transition, so move it to another track")
                    }
                }
            }
        }

        let total = zip(project.tracks, tracks).filter { $0.0.enabled }.flatMap { $0.1 }.map(\.endF).max() ?? 0
        if total == 0 && issues.isEmpty { issues.add("tracks", "nothing to render: no enabled track has a clip") }
        if !issues.isEmpty { throw ProjectError(issues.list) }
        return Plan(project: project, fps: fps, totalF: total, tracks: tracks, warnings: warnings)
    }

    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - Report

public struct PlanReport: Encodable {
    public struct ClipReport: Encodable {
        public let id: String
        public let kind: String
        public let src: String?
        public let start: Double
        public let end: Double
        public let duration: Double
        public let sourceIn: Double?
        public let sourceOut: Double?
        public let speed: Double?
        public let transition: String?
        public let transitionDuration: Double?
        public let text: String?
    }
    public struct TrackReport: Encodable {
        public let id: String
        public let enabled: Bool
        public let clips: [ClipReport]
    }
    public let duration: Double
    public let frames: Int
    public let width: Int
    public let height: Int
    public let fps: Double
    public let output: String?
    public let tracks: [TrackReport]
    public let warnings: [String]

    public init(_ plan: Plan) {
        let project = plan.project
        duration = plan.duration
        frames = plan.totalF
        width = project.output.width
        height = project.output.height
        fps = plan.fps
        output = project.output.path.map(project.resolve)
        warnings = plan.warnings
        tracks = zip(project.tracks, plan.tracks).map { track, clips in
            TrackReport(id: track.id, enabled: track.enabled, clips: clips.map { p in
                var kind = "fill", src: String?, text: String?
                var sourceIn: Double?, sourceOut: Double?, speed: Double?
                switch p.clip.kind {
                case .media(let raw):
                    src = project.resolve(raw)
                    let info = p.info
                    kind = info?.isImage == true ? "image" : (info?.hasVideo == true ? "video" : "audio")
                    if info?.isImage != true {
                        sourceIn = p.sourceIn
                        sourceOut = min(p.sourceIn + plan.seconds(p.durF) * p.clip.speed, info?.duration ?? .infinity)
                        sourceOut = (sourceOut! * 1000).rounded() / 1000
                        speed = p.clip.speed
                    }
                case .fill: break
                case .text(let spec):
                    kind = "text"
                    text = spec.lines.map(\.text).joined(separator: " / ")
                }
                return ClipReport(id: p.clip.id, kind: kind, src: src, start: plan.seconds(p.startF), end: plan.seconds(p.endF),
                                  duration: plan.seconds(p.durF), sourceIn: sourceIn, sourceOut: sourceOut, speed: speed,
                                  transition: p.clip.transition?.type,
                                  transitionDuration: p.transitionF > 0 ? plan.seconds(p.transitionF) : nil, text: text)
            })
        }
    }
}
