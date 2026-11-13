import ArgumentParser
import CutsKit
import Foundation

@main
struct Cuts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cuts",
        abstract: "A video editor with no window: tracks, titles and transitions described in JSON, rendered by ffmpeg.",
        discussion: "Every command prints JSON on stdout. Problems are printed as JSON on stderr with a non-zero exit code.\nRun `cuts format` for the project file reference.",
        version: "0.1.0",
        subcommands: [Render.self, PlanCommand.self, Check.self, Frame.self, Sheet.self, Probe.self, Transitions.self, Format.self]
    )
}

struct ErrorReport: Encodable {
    let error: String
    let issues: [Issue]?
}

/// Runs a command body, turning anything thrown into JSON on stderr and exit code 1.
func run(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as ProjectError {
        fail(ErrorReport(error: "the project has \(error.issues.count) problem\(error.issues.count == 1 ? "" : "s")", issues: error.issues))
    } catch let error as ExitCode {
        throw error
    } catch {
        fail(ErrorReport(error: "\(error)", issues: nil))
    }
}

func fail(_ report: ErrorReport) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(report) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }
    Foundation.exit(1)
}

func loadPlan(_ path: String) throws -> Plan {
    try Planner.make(try Project.load(path: path))
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render the project to a video file.")
    @Argument(help: "The project file.") var project: String
    @Option(name: [.short, .long], help: "Where to write the video (default: the project's output.path).") var output: String?
    @Flag(help: "Half size and fast, for checking timing rather than quality.") var draft = false
    @Flag(help: "Show ffmpeg's progress on stderr.") var progress = false

    func run() throws {
        try cuts.run {
            let plan = try loadPlan(project)
            guard let out = output ?? plan.project.output.path.map(plan.project.resolve) else {
                throw ToolError("no output: give -o, or set output.path in the project")
            }
            printJSON(try Renderer.render(plan: plan, output: out, draft: draft, progress: progress))
        }
    }
}

struct PlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Print the resolved timeline: where every clip starts and ends, in seconds.")
    @Argument(help: "The project file.") var project: String
    @Flag(help: "Print the ffmpeg command instead (its generated images are kept in a temporary folder).") var command = false

    func run() throws {
        try cuts.run {
            let plan = try loadPlan(project)
            guard command else { return printJSON(PlanReport(plan)) }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cuts-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let out = plan.project.output.path.map(plan.project.resolve) ?? "out.mp4"
            let (args, _) = try Renderer.renderArguments(plan: plan, output: out, draft: false, temp: temp)
            print((["ffmpeg"] + args).map(shellQuote).joined(separator: " "))
        }
    }

    func shellQuote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_./:=+@%-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Validate the project without rendering. Lists every problem found.")
    @Argument(help: "The project file.") var project: String

    struct Report: Encodable {
        let ok: Bool
        let duration: Double
        let clips: Int
        let warnings: [String]
    }

    func run() throws {
        try cuts.run {
            let plan = try loadPlan(project)
            printJSON(Report(ok: true, duration: plan.duration, clips: plan.tracks.reduce(0) { $0 + $1.count }, warnings: plan.warnings))
        }
    }
}

struct Frame: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save one frame of the finished edit as a PNG.")
    @Argument(help: "The project file.") var project: String
    @Option(help: "Time on the timeline, in seconds, or a clip edge such as intro.end-0.5.") var at: String
    @Option(help: "Width in pixels (default: full size).") var width: Int?
    @Option(name: [.short, .long], help: "The PNG to write.") var output: String

    func run() throws {
        try cuts.run {
            let plan = try loadPlan(project)
            printJSON(try Renderer.frame(plan: plan, at: try timelineSeconds(at, plan), width: width, output: output))
        }
    }
}

struct Sheet: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a contact sheet of the finished edit: timestamped frames in a grid.",
        discussion: "With neither --at nor --every, the sheet shows the middle of every clip and of every transition.")
    @Argument(help: "The project file.") var project: String
    @Option(help: "Comma-separated times: seconds, or clip edges such as title.start+0.2.") var at: String?
    @Option(help: "One frame every this many seconds.") var every: Double?
    @Option(help: "Columns in the grid.") var columns = 4
    @Option(help: "Width of each frame in pixels.") var width = 640
    @Option(name: [.short, .long], help: "The PNG to write.") var output: String

    func run() throws {
        try cuts.run {
            let plan = try loadPlan(project)
            var times: [Double] = []
            let last = plan.seconds(plan.totalF - 1)
            if let at {
                times = try at.split(separator: ",").map { try timelineSeconds(String($0), plan) }
            } else if let every {
                guard every > 0 else { throw ToolError("--every must be more than 0") }
                var t = 0.0
                while t <= last { times.append(t); t += every }
            } else {
                // The moments worth checking: mid-transition and mid-clip, on every track.
                var marks = Set<Int>()
                for clips in plan.tracks {
                    for p in clips {
                        if p.transitionF > 0 { marks.insert(p.startF + p.transitionF / 2) }
                        marks.insert(p.startF + (p.durF + p.transitionF - p.outgoingF) / 2)
                    }
                }
                // Marks from different tracks often land almost together; one frame of each moment is enough.
                var kept: [Int] = []
                for mark in marks.sorted() where kept.last.map({ mark - $0 >= Int(plan.fps / 2) }) ?? true { kept.append(mark) }
                times = kept.map(plan.seconds).filter { $0 <= last }
            }
            guard !times.isEmpty else { throw ToolError("no times to show") }
            guard times.count <= 200 else { throw ToolError("\(times.count) frames is too many for one sheet; use a larger --every") }
            printJSON(try Renderer.sheet(plan: plan, times: times, columns: columns, cellWidth: width, output: output))
        }
    }
}

/// Seconds, or `<clip id>.start` / `<clip id>.end` with an optional offset, read off the resolved plan.
func timelineSeconds(_ text: String, _ plan: Plan) throws -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if let seconds = Double(trimmed) { return seconds }
    if case .ref(let id, let edge, let offset)? = TimeExpr.reference(trimmed),
       let clip = plan.tracks.joined().first(where: { $0.clip.id == id }) {
        return plan.seconds(edge == .start ? clip.startF : clip.endF) + offset
    }
    throw ToolError("\"\(text)\" is neither seconds nor a clip edge such as intro.end-0.5")
}

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Describe media files: duration, size, frame rate, audio.")
    @Argument(help: "Video, audio or image files.") var files: [String]

    func run() throws {
        try cuts.run {
            printJSON(try files.map { try Tools.probe(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path) })
        }
    }
}

struct Transitions: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the transition names a clip can use.")
    func run() throws {
        printJSON(["crossfade", "dip-to-black", "dip-to-white"] + xfadeTransitions.filter { !["fade", "fadeblack", "fadewhite"].contains($0) })
    }
}

struct Format: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the project file reference.")
    func run() throws { print(formatReference) }
}
