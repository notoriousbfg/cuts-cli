import Foundation

public struct MediaInfo: Codable, Equatable {
    public var path: String
    public var duration: Double
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var isImage: Bool

    public init(path: String, duration: Double, width: Int? = nil, height: Int? = nil, fps: Double? = nil,
                hasVideo: Bool = true, hasAudio: Bool = false, isImage: Bool = false) {
        self.path = path; self.duration = duration; self.width = width; self.height = height
        self.fps = fps; self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.isImage = isImage
    }
}

public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Tools {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp", "heic"]

    /// `CUTS_FFMPEG` / `CUTS_FFPROBE`, then PATH, then the usual Homebrew folders.
    public static func locate(_ name: String) throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CUTS_\(name.uppercased())"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw ToolError("\(name) not found. Install it with `brew install ffmpeg`, or set CUTS_\(name.uppercased()).")
    }

    /// Runs a tool to completion. stderr is passed through when `echo` is set, else captured for the error.
    @discardableResult
    public static func run(_ tool: String, _ args: [String], echo: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = echo ? FileHandle.standardError : err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var errData = Data()
        let group = DispatchGroup()
        if !echo {
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = (tool as NSString).lastPathComponent
            throw ToolError("\(name) failed (exit \(process.terminationStatus))" + (message.isEmpty ? "" : ":\n\(message)"))
        }
        return data
    }

    public static func probe(_ path: String) throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: path) else { throw ToolError("no such file: \(path)") }
        let data = try run(try locate("ffprobe"), ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("ffprobe gave no data for \(path)")
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        let video = streams.first { $0["codec_type"] as? String == "video" && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let isImage = imageExtensions.contains((path as NSString).pathExtension.lowercased())
        var info = MediaInfo(path: path, duration: 0, hasVideo: video != nil, hasAudio: audio != nil, isImage: isImage)
        info.duration = Double(format["duration"] as? String ?? "") ?? Double(video?["duration"] as? String ?? "") ?? 0
        if isImage { info.duration = 0 }
        info.width = video?["width"] as? Int
        info.height = video?["height"] as? Int
        if let rate = (video?["avg_frame_rate"] ?? video?["r_frame_rate"]) as? String, !isImage {
            let parts = rate.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0 { info.fps = (parts[0] / parts[1] * 1000).rounded() / 1000 }
        }
        // Phone footage is stored sideways with a rotation tag; ffmpeg rotates it on decode.
        let sideData = video?["side_data_list"] as? [[String: Any]] ?? []
        if let rotation = sideData.compactMap({ $0["rotation"] as? Int }).first, abs(rotation) % 180 == 90 {
            swap(&info.width, &info.height)
        }
        return info
    }
}

public func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}
