import Foundation

public struct RenderOptions {
    /// Multiplies the canvas (and everything drawn on it); 0.5 renders a half-size draft.
    public var scale = 1.0
    /// Only these output frames will be read, so clips wholly outside them are skipped.
    public var window: ClosedRange<Int>?
    public var audio = true
    public init() {}
}

/// An ffmpeg invocation, minus the output: inputs, one filter graph and the labels to map.
public struct Job {
    public var inputs: [String]
    public var filter: String
    public var video: String
    public var audio: String?
    public var width: Int
    public var height: Int
    public var warnings: [String]
}

/// Turns a plan into one ffmpeg filter graph.
///
/// Every clip becomes a canvas-sized stream with alpha and an exact frame count. Each track joins its
/// clips end to end (`concat` for cuts, `xfade` for transitions, transparent filler for gaps), and the
/// tracks are then laid over the background in order.
final class GraphBuilder {
    let plan: Plan
    let options: RenderOptions
    let temp: URL
    let width: Int
    let height: Int
    let fps: String
    var inputs: [String] = []
    var inputCount = 0
    var filters: [String] = []
    var warnings: [String] = []
    private var counter = 0

    static let yuva = "format=pix_fmts=yuva444p:color_spaces=bt709:color_ranges=tv"

    init(plan: Plan, options: RenderOptions, temp: URL) {
        self.plan = plan
        self.options = options
        self.temp = temp
        width = GraphBuilder.even(Double(plan.project.output.width) * options.scale)
        height = GraphBuilder.even(Double(plan.project.output.height) * options.scale)
        fps = GraphBuilder.number(plan.fps)
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    static func number(_ v: Double) -> String {
        var s = String(format: "%.6f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    func time(_ frames: Int) -> String { GraphBuilder.number(Double(frames) / plan.fps) }

    func input(_ args: [String]) -> Int {
        inputs += args
        inputCount += 1
        return inputCount - 1
    }

    func label(_ prefix: String = "s") -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }

    /// Adds `[from]steps[new]` (or a source filter when `from` is nil) and returns the new label.
    @discardableResult
    func add(_ from: [String], _ steps: [String], prefix: String = "s") -> String {
        let out = label(prefix)
        filters.append(from.map { "[\($0)]" }.joined() + steps.joined(separator: ",") + "[\(out)]")
        return out
    }

    func asset(_ name: String) -> URL { temp.appendingPathComponent("\(label(name)).png") }

    func still(_ url: URL) -> Int { input(["-framerate", fps, "-i", url.path]) }

    /// Steps that turn a one-frame input into an endless stream at the output rate.
    var hold: [String] { ["loop=loop=-1:size=1:start=0", "setpts=N/(\(fps)*TB)", "fps=\(fps)"] }

    func transparent(_ frames: Int) -> String {
        add([], ["color=c=black@0.0:s=\(width)x\(height):r=\(fps):d=\(time(frames))", GraphBuilder.yuva], prefix: "gap")
    }

    func visible(_ p: PlannedClip) -> Bool {
        guard let window = options.window else { return true }
        return p.endF > window.lowerBound && p.startF <= window.upperBound
    }

    // MARK: Clips

    /// A canvas-sized, alpha-carrying stream of exactly `p.durF` frames starting at 0.
    func clipVideo(_ p: PlannedClip) throws -> String {
        let clip = p.clip
        let scale = options.scale
        var cur: String
        var steps: [String] = []

        switch clip.kind {
        case .fill(.color(let c)):
            cur = add([], ["color=c=\(c.ffmpeg):s=\(width)x\(height):r=\(fps):d=\(time(p.durF))", "format=rgba", GraphBuilder.yuva])
        case .fill(let gradient):
            let url = asset("fill")
            try Graphics.fillImage(gradient, width: width, height: height, to: url)
            cur = add(["\(still(url)):v"], hold + [GraphBuilder.yuva])
        case .text(let spec):
            let url = asset("text")
            try Graphics.text(spec, clip: clip, width: width, height: height, scale: scale,
                              resolve: plan.project.resolve, warnings: &warnings, to: url)
            cur = add(["\(still(url)):v"], hold + [GraphBuilder.yuva])
        case .media(let raw):
            let path = plan.project.resolve(raw)
            let info = p.info!
            let index: Int
            if info.isImage {
                index = still(URL(fileURLWithPath: path))
                steps = hold
            } else {
                let span = Double(p.durF) / plan.fps * clip.speed + 1
                index = input(["-ss", GraphBuilder.number(p.sourceIn), "-t", GraphBuilder.number(span), "-i", path])
                steps = ["setpts=(PTS-STARTPTS)/\(GraphBuilder.number(clip.speed))", "fps=\(fps)"]
            }

            // Where the picture lands on the canvas.
            var sw = Double(info.width ?? width), sh = Double(info.height ?? height)
            if let crop = clip.crop {
                let cw = max(2, (sw * crop.w).rounded()), ch = max(2, (sh * crop.h).rounded())
                steps.append("crop=\(Int(cw)):\(Int(ch)):\(Int((sw * crop.x).rounded())):\(Int((sh * crop.y).rounded()))")
                sw = cw; sh = ch
            }
            var w: Double, h: Double
            switch clip.fit {
            case .contain: let s = min(Double(width) / sw, Double(height) / sh); w = sw * s; h = sh * s
            case .cover: let s = max(Double(width) / sw, Double(height) / sh); w = sw * s; h = sh * s
            case .stretch: w = Double(width); h = Double(height)
            case .none: w = sw * scale; h = sh * scale
            }
            let pw = max(2, Int((w * clip.scale).rounded())), ph = max(2, Int((h * clip.scale).rounded()))
            let x = Int((clip.position.x * Double(width) - clip.anchor.x * Double(pw)).rounded())
            let y = Int((clip.position.y * Double(height) - clip.anchor.y * Double(ph)).rounded())
            steps += ["scale=\(pw):\(ph):flags=lanczos", "setsar=1", GraphBuilder.yuva]
            cur = add(["\(index):v"], steps)

            if clip.radius > 0 {
                let url = asset("mask")
                try Graphics.mask(width: pw, height: ph, radius: clip.radius * scale, to: url)
                let mask = add(["\(still(url)):v"], ["format=gray"], prefix: "mask")
                cur = add([cur, mask], ["alphamerge"])
            }

            let right = min(x + pw, width), bottom = min(y + ph, height)
            if let shadow = clip.shadow {
                let url = asset("shadow")
                try Graphics.shadow(canvasWidth: width, canvasHeight: height, rect: CGRect(x: x, y: y, width: pw, height: ph),
                                    radius: clip.radius * scale, spec: shadow, scale: scale, to: url)
                let under = add(["\(still(url)):v"], hold + [GraphBuilder.yuva], prefix: "shadow")
                cur = add([under, cur], ["overlay=x=\(x):y=\(y):format=auto:shortest=1", GraphBuilder.yuva])
            } else if right <= max(x, 0) || bottom <= max(y, 0) {
                warnings.append("\(clip.id): placed wholly outside the frame")
                cur = transparent(p.durF)
            } else if x != 0 || y != 0 || pw != width || ph != height {
                var place: [String] = []
                if x < 0 || y < 0 || x + pw > width || y + ph > height {
                    place.append("crop=\(right - max(x, 0)):\(bottom - max(y, 0)):\(max(-x, 0)):\(max(-y, 0))")
                }
                place.append("pad=\(width):\(height):\(max(x, 0)):\(max(y, 0)):color=black@0.0")
                cur = add([cur], place)
            }
        }

        // Exact length (holding the last frame if the source runs out), then opacity and fades.
        var finish = ["tpad=stop=-1:stop_mode=clone", "trim=end_frame=\(p.durF)", "setpts=PTS-STARTPTS"]
        if clip.opacity < 1 { finish.append("colorchannelmixer=aa=\(GraphBuilder.number(clip.opacity))") }
        let length = Double(p.durF) / plan.fps
        if clip.fadeIn > 0 {
            finish.append("fade=t=in:st=0:d=\(GraphBuilder.number(min(clip.fadeIn, length))):alpha=1")
        }
        if clip.fadeOut > 0 {
            let d = min(clip.fadeOut, length)
            finish.append("fade=t=out:st=\(GraphBuilder.number(length - d)):d=\(GraphBuilder.number(d)):alpha=1")
        }
        return add([cur], finish, prefix: "clip")
    }

    // MARK: Tracks

    func trackVideo(_ clips: [PlannedClip]) throws -> String? {
        var pending: [String] = []   // segments waiting to be joined end to end
        var end = 0                  // frames of track built so far

        func joined() -> String? {
            guard let first = pending.first else { return nil }
            let out = pending.count == 1 ? first : add(pending, ["concat=n=\(pending.count):v=1:a=0"], prefix: "cat")
            pending = [out]
            return out
        }

        for p in clips where p.hasVideo && visible(p) {
            if p.transitionF > 0 {
                // xfade needs what came before to reach the end of the overlap.
                let need = p.startF + p.transitionF
                if end < need { pending.append(transparent(need - end)) }
                let before = joined()!
                let next = try clipVideo(p)
                let out = add([before, next], [
                    "xfade=transition=\(p.clip.transition!.type):duration=\(time(p.transitionF)):offset=\(time(p.startF))",
                    GraphBuilder.yuva,
                ], prefix: "mix")
                pending = [out]
            } else {
                if end < p.startF { pending.append(transparent(p.startF - end)) }
                pending.append(try clipVideo(p))
            }
            end = p.endF
        }
        return joined()
    }

    // MARK: Audio

    func clipAudio(_ p: PlannedClip, trackVolume: Double) -> String {
        let clip = p.clip
        let length = Double(p.durF) / plan.fps
        let span = length * clip.speed + 1
        let index = input(["-ss", GraphBuilder.number(p.sourceIn), "-t", GraphBuilder.number(span), "-vn", "-i", plan.project.resolve({
            if case .media(let raw) = clip.kind { return raw }
            return ""
        }())])
        var steps = ["asetpts=PTS-STARTPTS"]
        // atempo takes 0.5–2 per instance, so chain it for bigger changes.
        var speed = clip.speed
        while speed > 2 { steps.append("atempo=2"); speed /= 2 }
        while speed < 0.5 { steps.append("atempo=0.5"); speed /= 0.5 }
        if abs(speed - 1) > 0.0001 { steps.append("atempo=\(GraphBuilder.number(speed))") }
        steps += ["aresample=48000", "aformat=sample_fmts=fltp:channel_layouts=stereo", "atrim=end=\(GraphBuilder.number(length))"]
        let volume = clip.volume * trackVolume
        if abs(volume - 1) > 0.0001 { steps.append("volume=\(GraphBuilder.number(volume))") }
        // A transition crossfades the sound of the two clips as well.
        let fadeIn = min(length, max(clip.fadeIn, Double(p.transitionF) / plan.fps))
        let fadeOut = min(length, max(clip.fadeOut, Double(p.outgoingF) / plan.fps))
        if fadeIn > 0 { steps.append("afade=t=in:st=0:d=\(GraphBuilder.number(fadeIn))") }
        if fadeOut > 0 { steps.append("afade=t=out:st=\(GraphBuilder.number(length - fadeOut)):d=\(GraphBuilder.number(fadeOut))") }
        let delay = Int((Double(p.startF) / plan.fps * 1000).rounded())
        if delay > 0 { steps.append("adelay=delays=\(delay):all=1") }
        return add(["\(index):a"], steps, prefix: "a")
    }

    // MARK: Whole timeline

    func build() throws -> Job {
        let project = plan.project
        let lastFrame = min(options.window?.upperBound ?? plan.totalF - 1, plan.totalF - 1)
        let length = lastFrame + 1

        var base: String
        switch project.output.background {
        case .color(let c):
            base = add([], ["color=c=\(c.ffmpeg):s=\(width)x\(height):r=\(fps):d=\(time(length))", "format=rgba",
                            "format=pix_fmts=yuv444p:color_spaces=bt709:color_ranges=tv"], prefix: "base")
        case .gradient:
            let url = asset("background")
            try Graphics.fillImage(project.output.background, width: width, height: height, to: url)
            base = add(["\(still(url)):v"], hold + ["format=pix_fmts=yuv444p:color_spaces=bt709:color_ranges=tv", "trim=end_frame=\(length)"], prefix: "base")
        }

        for (track, clips) in zip(project.tracks, plan.tracks) where track.enabled {
            guard let layer = try trackVideo(clips) else { continue }
            base = add([base, layer], ["overlay=eof_action=pass:format=yuv444"], prefix: "out")
        }
        let video = add([base], ["trim=end_frame=\(length)", "format=pix_fmts=yuv420p:color_spaces=bt709:color_ranges=tv"], prefix: "video")

        var audio: String?
        if options.audio {
            var parts: [String] = []
            for (track, clips) in zip(project.tracks, plan.tracks) where track.enabled && track.volume > 0 {
                for p in clips where p.hasAudio { parts.append(clipAudio(p, trackVolume: track.volume)) }
            }
            if !parts.isEmpty {
                // Silence the full length of the timeline, so the sound track never ends early.
                parts.append(add([], ["anullsrc=r=48000:cl=stereo", "atrim=end=\(time(plan.totalF))"], prefix: "a"))
                audio = add(parts, ["amix=inputs=\(parts.count):normalize=0:dropout_transition=0:duration=longest",
                                    "atrim=end=\(time(plan.totalF))"], prefix: "audio")
            }
        }
        return Job(inputs: inputs, filter: filters.joined(separator: ";\n"), video: video, audio: audio,
                   width: width, height: height, warnings: plan.warnings + warnings)
    }
}

// MARK: - Running ffmpeg

public struct RenderResult: Encodable {
    public let output: String
    public let duration: Double
    public let width: Int
    public let height: Int
    public let fps: Double
    public let hasAudio: Bool
    public let bytes: Int
    public let renderSeconds: Double
    public let warnings: [String]
}

public struct StillResult: Encodable {
    public let output: String
    public let times: [Double]
    public let width: Int
    public let height: Int
    public let warnings: [String]
}

public enum Renderer {
    static func withTemp<T>(keep: Bool = false, _ body: (URL) throws -> T) throws -> T {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cuts-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: temp) } }
        return try body(temp)
    }

    static func prepareOutput(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url.path
    }

    static func encoderArgs(_ output: Output, draft: Bool) -> [String] {
        var args: [String]
        if output.codec == "hevc" {
            args = ["-c:v", "libx265", "-crf", "\(draft ? 32 : output.crf ?? 22)", "-preset", draft ? "ultrafast" : "medium", "-tag:v", "hvc1",
                    "-x265-params", "log-level=error"]
        } else {
            args = ["-c:v", "libx264", "-crf", "\(draft ? 28 : output.crf ?? 18)", "-preset", draft ? "ultrafast" : "medium"]
        }
        return args + ["-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                       "-color_range", "tv", "-movflags", "+faststart"]
    }

    /// The full ffmpeg argument list for a render. Generated images are written into `temp`.
    public static func renderArguments(plan: Plan, output: String, draft: Bool, temp: URL) throws -> (args: [String], job: Job) {
        var options = RenderOptions()
        options.scale = draft ? 0.5 : 1
        let job = try GraphBuilder(plan: plan, options: options, temp: temp).build()
        var args = ["-hide_banner", "-y", "-loglevel", "error"] + job.inputs + ["-filter_complex", job.filter, "-map", "[\(job.video)]"]
        if let audio = job.audio { args += ["-map", "[\(audio)]", "-c:a", "aac", "-b:a", "192k"] }
        args += ["-r", GraphBuilder.number(plan.fps)] + encoderArgs(plan.project.output, draft: draft) + [output]
        return (args, job)
    }

    public static func render(plan: Plan, output: String, draft: Bool = false, progress: Bool = false) throws -> RenderResult {
        let out = try prepareOutput(output)
        let ffmpeg = try Tools.locate("ffmpeg")
        let started = Date()
        return try withTemp { temp in
            var (args, job) = try renderArguments(plan: plan, output: out, draft: draft, temp: temp)
            if progress { args.insert("-stats", at: 1) }
            try Tools.run(ffmpeg, args, echo: progress)
            let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
            return RenderResult(output: out, duration: plan.duration, width: job.width, height: job.height, fps: plan.fps,
                                hasAudio: job.audio != nil, bytes: size,
                                renderSeconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, warnings: job.warnings)
        }
    }

    static func frameIndex(_ plan: Plan, _ seconds: Double) throws -> Int {
        let frame = Int((seconds * plan.fps).rounded())
        guard frame >= 0, frame < plan.totalF else {
            throw ToolError("\(seconds) s is outside the timeline, which is \(plan.seconds(plan.totalF)) s long")
        }
        return frame
    }

    /// Renders chosen frames of the finished edit as PNGs in `temp`, in the order given.
    static func stills(plan: Plan, frames: [Int], width: Int?, temp: URL) throws -> (files: [URL], job: Job) {
        let order = Array(Set(frames)).sorted()
        var options = RenderOptions()
        options.audio = false
        options.window = order.first!...order.last!
        if let width { options.scale = min(1, Double(width) / Double(plan.project.output.width)) }
        let job = try GraphBuilder(plan: plan, options: options, temp: temp).build()
        let pick = order.map { "eq(n,\($0))" }.joined(separator: "+")
        let filter = job.filter + ";\n[\(job.video)]select='\(pick)',format=rgb24[pick]"
        let pattern = temp.appendingPathComponent("frame-%04d.png").path
        try Tools.run(try Tools.locate("ffmpeg"), ["-hide_banner", "-y", "-loglevel", "error"] + job.inputs
            + ["-filter_complex", filter, "-map", "[pick]", "-fps_mode", "passthrough", "-frames:v", "\(order.count)", pattern])
        let byFrame = Dictionary(uniqueKeysWithValues: order.enumerated().map { i, f in
            (f, temp.appendingPathComponent(String(format: "frame-%04d.png", i + 1)))
        })
        return (frames.map { byFrame[$0]! }, job)
    }

    public static func frame(plan: Plan, at seconds: Double, width: Int? = nil, output: String) throws -> StillResult {
        let out = try prepareOutput(output)
        let index = try frameIndex(plan, seconds)
        return try withTemp { temp in
            let (files, job) = try stills(plan: plan, frames: [index], width: width, temp: temp)
            guard FileManager.default.fileExists(atPath: files[0].path) else { throw ToolError("ffmpeg produced no frame at \(seconds) s") }
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.moveItem(at: files[0], to: URL(fileURLWithPath: out))
            return StillResult(output: out, times: [plan.seconds(index)], width: job.width, height: job.height, warnings: job.warnings)
        }
    }

    public static func sheet(plan: Plan, times: [Double], columns: Int = 4, cellWidth: Int = 640, output: String) throws -> StillResult {
        let out = try prepareOutput(output)
        let indices = try times.map { try frameIndex(plan, $0) }
        return try withTemp { temp in
            let (files, job) = try stills(plan: plan, frames: indices, width: cellWidth, temp: temp)
            let labels = indices.enumerated().map { i, f in "#\(i + 1)  \(String(format: "%.2f", plan.seconds(f)))s" }
            try Graphics.sheet(frames: files, labels: labels, columns: columns, title: nil, to: URL(fileURLWithPath: out))
            return StillResult(output: out, times: indices.map(plan.seconds), width: job.width, height: job.height, warnings: job.warnings)
        }
    }
}
