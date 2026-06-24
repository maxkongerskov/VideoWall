import XCTest
@testable import VideoWall

// MARK: - ClipBounds

final class ClipBoundsTests: XCTestCase {

    func testZeroDurationIsNone() {
        let b = ClipBounds.compute(total: 0, trimStart: 0, trimEnd: 1)
        XCTAssertEqual(b.start, 0)
        XCTAssertEqual(b.end, 0)
        XCTAssertEqual(b.length, 0)
    }

    func testFullClip() {
        let b = ClipBounds.compute(total: 100, trimStart: 0, trimEnd: 1)
        XCTAssertEqual(b.start, 0, accuracy: 0.0001)
        XCTAssertEqual(b.end, 100, accuracy: 0.0001)
        XCTAssertEqual(b.length, 100, accuracy: 0.0001)
    }

    func testTrimmedEnd() {
        let b = ClipBounds.compute(total: 100, trimStart: 0.5, trimEnd: 1.0)
        XCTAssertEqual(b.start, 50, accuracy: 0.0001)
        XCTAssertEqual(b.end, 100, accuracy: 0.0001)
        XCTAssertEqual(b.length, 50, accuracy: 0.0001)
    }

    /// The trim+crossfade fix: a clip trimmed to start late must report its
    /// real (short) length, not the absolute end timestamp.
    func testTrimmedStartReportsClipLengthNotAbsoluteEnd() {
        let b = ClipBounds.compute(total: 100, trimStart: 0.5, trimEnd: 0.6)
        XCTAssertEqual(b.start, 50, accuracy: 0.0001)
        XCTAssertEqual(b.end, 60, accuracy: 0.0001)
        XCTAssertEqual(b.length, 10, accuracy: 0.0001)
    }

    func testInvertedTrimClampsToZeroLength() {
        let b = ClipBounds.compute(total: 100, trimStart: 0.8, trimEnd: 0.2)
        XCTAssertGreaterThanOrEqual(b.length, 0, "length must never go negative")
        XCTAssertEqual(b.length, 0, accuracy: 0.0001)
    }
}

// MARK: - VideoItem

final class VideoItemTests: XCTestCase {

    private func item(duration: TimeInterval) -> VideoItem {
        VideoItem(id: UUID(), name: "clip", filename: "clip.mp4",
                  duration: duration, thumbnailData: nil)
    }

    func testDurationStringUnderAnHour() {
        XCTAssertEqual(item(duration: 65).durationString, "1:05")
        XCTAssertEqual(item(duration: 0).durationString, "0:00")
    }

    func testDurationStringOverAnHour() {
        XCTAssertEqual(item(duration: 3661).durationString, "1:01:01")
    }

    func testDurationStringHandlesNonFinite() {
        XCTAssertEqual(item(duration: .nan).durationString, "00:00")
        XCTAssertEqual(item(duration: -5).durationString, "00:00")
    }

    func testSupportedExtensions() {
        XCTAssertTrue(VideoItem.supportedExtensions.contains("mp4"))
        XCTAssertTrue(VideoItem.supportedExtensions.contains("mov"))
        XCTAssertFalse(VideoItem.supportedExtensions.contains("txt"))
    }

    func testEqualityIsByID() {
        let id = UUID()
        let a = VideoItem(id: id, name: "A", filename: "a.mp4", duration: 1, thumbnailData: nil)
        let b = VideoItem(id: id, name: "B (renamed)", filename: "a.mp4", duration: 1, thumbnailData: nil)
        XCTAssertEqual(a, b, "items with the same id are equal regardless of name")
    }
}

// MARK: - VideoResolution

final class VideoResolutionTests: XCTestCase {

    func testOriginalHasNoRenderSize() {
        XCTAssertNil(VideoResolution.original.renderSize)
    }

    func testFixedRenderSizes() {
        XCTAssertEqual(VideoResolution.hd720.renderSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(VideoResolution.fhd1080.renderSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoResolution.uhd4k.renderSize, CGSize(width: 3840, height: 2160))
    }

    func testRawValueRoundTrips() {
        for res in VideoResolution.allCases {
            XCTAssertEqual(VideoResolution(rawValue: res.rawValue), res)
        }
    }
}
