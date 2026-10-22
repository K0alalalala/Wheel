import AppKit
import SwiftUI
import XCTest
@testable import Wheel
@testable import WheelCore

final class WheelLogTests: XCTestCase {
    private var dir: URL!
    private var log: WheelLog!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("WheelLogTests-\(UUID().uuidString)")
        log = WheelLog(directory: dir)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func contents() throws -> String {
        log.flush()
        return try String(contentsOf: log.logFile, encoding: .utf8)
    }

    func testWritesPrivatelyWithSourceAndLevel() throws {
        log.info("hello")
        log.error("boom")
        let text = try contents()
        XCTAssertTrue(text.contains("[info] DiagnosticsTests.swift:"), text)
        XCTAssertTrue(text.contains("[error]") && text.contains("boom"))
        let fileMode = try FileManager.default.attributesOfItem(atPath: log.logFile.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600, "only the user can read the log")
        XCTAssertEqual(dirMode, 0o700)
    }

    func testOptOutWritesNothing() throws {
        log.isEnabled = false
        log.info("should not appear")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logFile.path))
        log.isEnabled = true
        log.info("back on")
        XCTAssertFalse(try contents().contains("should not appear"))
    }

    func testRedactsHomePathsAndFileNames() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let file = URL(fileURLWithPath: home + "/Desktop/Salary Review 2026.pdf")
        log.error("ffmpeg: \(home)/Movies/Secret Trip.mov: Invalid data")
        log.info(log.redact("Couldn't open Salary Review 2026.pdf", files: [file]))
        XCTAssertEqual(log.describe(file), "‹pdf›")
        let text = try contents()
        XCTAssertFalse(text.contains(home), "home path leaked")
        XCTAssertFalse(text.contains("Secret Trip"), "path leaked: \(text)")
        XCTAssertFalse(text.contains("Salary Review"), "file name leaked: \(text)")
        XCTAssertTrue(text.contains("‹path›") && text.contains("‹pdf›"), text)

        log.includeFileNames = true
        XCTAssertEqual(log.describe(file), "Salary Review 2026.pdf")
        XCTAssertEqual(log.redact("at \(home)/Desktop/x/Notes.txt"), "at Notes.txt", "opted in: name only, still no path")
    }

    func testRotationKeepsSizeBounded() throws {
        log.maxBytes = 2_000
        log.keepFiles = 3
        for i in 0..<200 { log.info("line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()
        let logs = log.files.filter { $0.pathExtension == "log" }.map(\.lastPathComponent).sorted()
        XCTAssertEqual(logs, ["wheel.1.log", "wheel.2.log", "wheel.log"])
        XCTAssertLessThan(log.totalSize, 3 * 2_200)
        log.deleteAll()
        XCTAssertTrue(log.files.isEmpty)
    }

    func testCrashSummaryKeepsStackAndDropsRegisters() throws {
        let header = #"{"app_version":"0.4.0","bundleID":"io.github.k0alalalala.wheel","timestamp":"2026-10-22 18:27:39","os_version":"macOS 27.0"}"#
        let body: [String: Any] = [
            "exception": ["type": "EXC_CRASH", "signal": "SIGABRT"],
            "termination": ["indicator": "Abort trap: 6"],
            "faultingThread": 0,
            "usedImages": [["name": "AppKit"], ["name": "SwiftUI"]],
            "threads": [["queue": "com.apple.main-thread", "threadState": ["x": [["value": 42]]],
                         "frames": [["imageIndex": 0, "symbol": "_nsis_frameInEngine"],
                                    ["imageIndex": 1, "symbol": "AppKitPlatformViewHost.fittingSize.getter"]]]],
        ]
        let ips = header + "\n" + String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        let summary = try XCTUnwrap(CrashReporter.summarize(ips))
        XCTAssertTrue(summary.contains("EXC_CRASH SIGABRT"))
        XCTAssertTrue(summary.contains("_nsis_frameInEngine") && summary.contains("fittingSize"))
        XCTAssertFalse(summary.contains("threadState") || summary.contains("42"), "no register state")
        XCTAssertNil(CrashReporter.summarize(#"{"bundleID":"com.other.app"}"# + "\n{}"), "other apps' reports are ignored")
    }
}

@MainActor
final class GlassSizingTests: XCTestCase {
    /// Regression for the 0.4.0 crash: the blur must size from the proposal, never via Auto Layout.
    func testGlassFillsOfferedSpaceInsideZStack() {
        let host = NSHostingView(rootView: ZStack { GlassBackground(shape: .circle) }.frame(width: 120, height: 80))
        host.layout()
        XCTAssertEqual(host.fittingSize, CGSize(width: 120, height: 80))
    }
}
