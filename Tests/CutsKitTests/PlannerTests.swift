import XCTest
@testable import CutsKit

final class PlannerTests: XCTestCase {
    func plan(_ json: String) throws -> Plan {
        let project = try Project.parse(data: Data(json.utf8), baseDir: URL(fileURLWithPath: "/project"))
        return try Planner.make(project) { path in
            MediaInfo(path: path, duration: 10, width: 1280, height: 720, fps: 30, hasVideo: true, hasAudio: path.hasSuffix("sound.mp4"))
        }
    }

    func issues(_ json: String) -> [Issue] {
        do { _ = try plan(json); return [] } catch let error as ProjectError { return error.issues } catch { return [Issue(path: "?", message: "\(error)")] }
    }

    func testClipsFollowEachOtherAndTransitionsOverlap() throws {
        let p = try plan(##"""
        {"tracks":[{"clips":[
          {"id":"a","src":"a.mp4","in":2,"out":6},
          {"id":"b","src":"b.mp4","out":4,"speed":2,"transition":{"type":"crossfade","duration":1}},
          {"id":"c","fill":"#000","duration":1.5}]}]}
        """##)
        let clips = p.tracks[0]
        XCTAssertEqual(clips.map(\.startF), [0, 90, 150])
        XCTAssertEqual(clips.map(\.durF), [120, 60, 45])
        XCTAssertEqual(clips[1].transitionF, 30)
        XCTAssertEqual(clips[0].outgoingF, 30)
        XCTAssertFalse(clips[1].transitionFromGap)
        XCTAssertEqual(p.totalF, 195)
    }

    func testReferencesToOtherClips() throws {
        let p = try plan(##"""
        {"tracks":[
          {"clips":[{"id":"intro","fill":"#000","duration":2},{"id":"main-shot","src":"a.mp4"}]},
          {"clips":[{"id":"cap","text":"Hello","start":"main-shot.start+0.5","end":"main-shot.end-1"}]}]}
        """##)
        let caption = p.tracks[1][0]
        XCTAssertEqual(caption.startF, 75)
        XCTAssertEqual(caption.endF, 330)
        XCTAssertTrue(p.tracks[1][0].clip.transition == nil)
    }

    func testTransitionWithNothingBeforeComesFromTheGap() throws {
        let p = try plan(##"{"tracks":[{"clips":[{"fill":"#fff","start":3,"transition":"wipeleft"}]}]}"##)
        XCTAssertTrue(p.tracks[0][0].transitionFromGap)
        XCTAssertEqual(p.tracks[0][0].clip.transition?.type, "wipeleft")
    }

    func testProblemsAreAllReportedWithPaths() {
        let found = issues(##"""
        {"output":{"widht":1280},"tracks":[{"clips":[
          {"src":"a.mp4","out":12},
          {"fill":"#000","text":"both"},
          {"text":"x","transition":"sparkle"},
          {"fill":"red"}]}]}
        """##)
        let paths = found.map(\.path)
        XCTAssertTrue(paths.contains("output.widht"))
        XCTAssertTrue(paths.contains("tracks[0].clips[1]"))
        XCTAssertTrue(paths.contains("tracks[0].clips[2].transition"))
        XCTAssertTrue(paths.contains("tracks[0].clips[3].fill"))
    }

    func testOverlapWithoutTransitionIsAnError() {
        let found = issues(##"{"tracks":[{"clips":[{"id":"a","fill":"#000","duration":4},{"fill":"#fff","start":2}]}]}"##)
        XCTAssertEqual(found.map(\.path), ["tracks[0].clips[1].start"])
        XCTAssertTrue(issues(##"{"tracks":[{"clips":[{"src":"a.mp4","out":12}]}]}"##).first?.path == "tracks[0].clips[0].out")
        XCTAssertTrue(issues(##"{"tracks":[{"clips":[{"id":"a","fill":"#000","start":"a.end"}]}]}"##).contains { $0.message.contains("depends on itself") })
    }

    func testGraphHasOneStreamPerClipAndAudioOnlyWhenThereIsSound() throws {
        let p = try plan(##"""
        {"tracks":[{"clips":[{"src":"sound.mp4","out":2},{"src":"a.mp4","out":2,"transition":"crossfade"}]}]}
        """##)
        let job = try GraphBuilder(plan: p, options: RenderOptions(), temp: FileManager.default.temporaryDirectory).build()
        XCTAssertEqual(job.filter.components(separatedBy: "xfade=transition=fade:duration=0.5:offset=1.5").count, 2)
        XCTAssertNotNil(job.audio)
        XCTAssertTrue(job.filter.contains("afade=t=out:st=1.5:d=0.5"))
        XCTAssertEqual(job.inputs.filter { $0 == "-i" }.count, 3)
    }

    func testColours() {
        XCTAssertEqual(RGBA("#fff"), .white)
        XCTAssertEqual(RGBA("#00000080")?.a ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(RGBA("red"))
    }
}
