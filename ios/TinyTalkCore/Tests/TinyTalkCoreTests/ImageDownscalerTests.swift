import XCTest
@testable import TinyTalkCore

final class ImageDownscalerTests: XCTestCase {
    func testALargePNGBecomesAJPEGWithItsLongSideAtMostFiveHundredTwelve() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 1024, height: 768)))
        XCTAssertTrue(TestImages.isJPEG(jpeg))
        let size = try XCTUnwrap(TestImages.pixelSize(of: jpeg))
        XCTAssertEqual(max(size.width, size.height), 512)
        XCTAssertEqual(Double(size.width) / Double(size.height), 4.0 / 3.0, accuracy: 0.02, "the aspect ratio must be kept")
    }

    func testATallImageIsLimitedOnItsHeight() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 600, height: 1200)))
        let size = try XCTUnwrap(TestImages.pixelSize(of: jpeg))
        XCTAssertEqual(size.height, 512)
        XCTAssertEqual(size.width, 256)
    }

    func testAnImageAlreadySmallerThanTheLimitIsNeverLargerThanTheLimit() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 100, height: 50)))
        XCTAssertTrue(TestImages.isJPEG(jpeg))
        let size = try XCTUnwrap(TestImages.pixelSize(of: jpeg))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
    }

    func testTheOutputIsSmallEnoughToUploadCheaply() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 1024, height: 1024)))
        XCTAssertLessThan(jpeg.count, 100_000)
    }

    func testBytesThatAreNotAnImageGiveNil() {
        XCTAssertNil(ImageDownscaler.jpeg(from: Data("definitely not an image".utf8)))
        XCTAssertNil(ImageDownscaler.jpeg(from: Data()))
    }
}
