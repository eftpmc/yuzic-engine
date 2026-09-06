import XCTest
@testable import YuzicEngineCore

/// Emits chunks on demand so the timing of a stream is under the test's
/// control rather than the network's.
final class FakeProducer: StreamProducer, @unchecked Sendable {
  private var onData: ((Data) -> Void)?
  private var onFinish: ((Error?) -> Void)?
  private(set) var stopped = false
  private(set) var begun = false

  func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void) {
    begun = true
    self.onData = onData
    self.onFinish = onFinish
  }

  func stop() { stopped = true }

  func emit(_ bytes: Int, startingAt value: Int = 0) {
    var chunk = Data(count: bytes)
    for index in 0..<bytes { chunk[index] = UInt8((value + index) % 251) }
    onData?(chunk)
  }

  func finish(error: Error? = nil) { onFinish?(error) }
}

/**
 The transcoded transport: bytes arrive in order and there is no going back to
 the server for a range it already refused.
 */
final class StreamingByteSourceTests: XCTestCase {

  private func makeSource(estimate: Int64 = 100_000) -> (StreamingByteSource, FakeProducer) {
    let producer = FakeProducer()
    return (StreamingByteSource(producer: producer, estimatedBytes: estimate), producer)
  }

  func testDoesNotStartTheStreamUntilSomethingReadsIt() {
    let (_, producer) = makeSource()
    XCTAssertFalse(producer.begun)
  }

  func testReportsTheEstimateBeforeTheStreamEnds() throws {
    let (source, _) = makeSource(estimate: 100_000)
    // The parser asks before a single byte has arrived, and something has to be
    // said. Duration times bitrate is what the host knows.
    XCTAssertEqual(try source.totalBytes(), 100_000)
  }

  func testReportsTheTrueSizeOnceTheStreamHasEnded() throws {
    let (source, producer) = makeSource(estimate: 100_000)
    DispatchQueue.global().async {
      producer.emit(4096)
      producer.finish()
    }
    _ = try source.read(offset: 0, count: 16)
    // Better than the estimate, and a parser seeking relative to the end needs
    // the real one.
    XCTAssertEqual(try source.totalBytes(), 4096)
  }

  func testReadsWaitForTheWriteHeadToCatchUp() throws {
    let (source, producer) = makeSource()

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      producer.emit(1000)
      producer.emit(1000, startingAt: 1000)
    }

    // A reader slightly ahead of the download is the normal case, not an error.
    let data = try source.read(offset: 1500, count: 100)
    XCTAssertEqual(data.count, 100)
    XCTAssertEqual(data.first, UInt8(1500 % 251))
  }

  func testSeekingBackwardsIsFreeBecauseEveryByteIsKept() throws {
    let (source, producer) = makeSource()
    DispatchQueue.global().async {
      producer.emit(8192)
      producer.finish()
    }
    _ = try source.read(offset: 8000, count: 100)

    // The whole point of keeping the bytes: within what has arrived this is an
    // ordinary random-access file.
    let early = try source.read(offset: 10, count: 50)
    XCTAssertEqual(early.count, 50)
    XCTAssertEqual(early.first, UInt8(10))
  }

  func testAReadPastTheEndOfAFinishedStreamReturnsNothing() throws {
    let (source, producer) = makeSource()
    DispatchQueue.global().async {
      producer.emit(1000)
      producer.finish()
    }
    _ = try source.read(offset: 0, count: 10)
    // Empty rather than an error: Core Audio reads that as end-of-file.
    XCTAssertTrue(try source.read(offset: 5000, count: 100).isEmpty)
  }

  func testAShortReadAtTheEndIsNotAnError() throws {
    let (source, producer) = makeSource()
    DispatchQueue.global().async {
      producer.emit(1000)
      producer.finish()
    }
    XCTAssertEqual(try source.read(offset: 900, count: 500).count, 100)
  }

  func testCancellingUnblocksAWaitingRead() throws {
    let (source, _) = makeSource()

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { source.cancel() }

    // Without this a seek would deadlock against a stream that has stalled.
    XCTAssertThrowsError(try source.read(offset: 50_000, count: 100)) { error in
      XCTAssertEqual(error as? ByteSourceError, .cancelled)
    }
  }

  func testAFailedStreamSurfacesRatherThanHanging() throws {
    let (source, producer) = makeSource()
    struct Boom: Error {}
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      producer.finish(error: Boom())
    }
    XCTAssertThrowsError(try source.read(offset: 0, count: 100))
  }

  func testAvailableBytesTracksTheWriteHead() throws {
    let (source, producer) = makeSource()
    DispatchQueue.global().async {
      producer.emit(2048)
      producer.finish()
    }
    _ = try source.read(offset: 0, count: 1)
    XCTAssertEqual(source.availableBytes(from: 0), 2048)
    XCTAssertEqual(source.availableBytes(from: 2000), 48)
    XCTAssertEqual(source.availableBytes(from: 4000), 0)
  }

  // MARK: - timeOffset, the seek that is really a reconnection

  func testTimeOffsetIsAddedToTheStreamURL() {
    let base = URL(string: "https://music.example/rest/stream.view?id=42&maxBitRate=128")!
    let seeked = streamURL(base: base, timeOffsetSeconds: 90)
    XCTAssertTrue(seeked.absoluteString.contains("timeOffset=90"))
    XCTAssertTrue(seeked.absoluteString.contains("id=42"))
    XCTAssertTrue(seeked.absoluteString.contains("maxBitRate=128"))
  }

  func testTimeOffsetReplacesRatherThanRepeats() {
    let base = URL(string: "https://music.example/rest/stream.view?id=42&timeOffset=30")!
    let seeked = streamURL(base: base, timeOffsetSeconds: 90)
    XCTAssertTrue(seeked.absoluteString.contains("timeOffset=90"))
    XCTAssertFalse(seeked.absoluteString.contains("timeOffset=30"))
  }

  func testSeekingToZeroLeavesTheURLAlone() {
    let base = URL(string: "https://music.example/rest/stream.view?id=42")!
    XCTAssertEqual(streamURL(base: base, timeOffsetSeconds: 0), base)
  }
}
