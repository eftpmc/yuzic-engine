import XCTest
@testable import YuzicEngineCore

/**
 A seek must not end the stream it is seeking within.

 Separate from `StreamingByteSourceTests` because these need a producer double
 that *actually stops* on `stop()`. `FakeProducer` there records the call and
 keeps delivering, which is convenient for the tests it serves and is exactly
 why the suite could not see this bug: the real `HTTPStreamProducer.stop()`
 cancels its task and invalidates its session, so the stream is over for good.
 A double that models a stop as a flag makes an irreversible teardown look
 reversible.

 The bug: `cancel()` called `producer.stop()`, `resume()` only cleared a
 boolean, and `startIfNeeded()` is guarded by a `started` flag that is never
 reset — so nothing ever restarted the producer. Every seek routes through
 `cancelPendingReads()`/`resumePendingReads()` on the same source, so the first
 seek killed the transcode and every later read waited out the twelve-second
 timeout and threw. On a device that is silence, and then a track that ends
 itself. Reported against "Life Is Good"; the same track downloaded was fine,
 which is the tell — a local file never takes this path.
 */
final class StreamingByteSourceSeekTests: XCTestCase {

  /// Stops delivering when stopped, like the HTTP producer it stands in for.
  private final class HonestProducer: StreamProducer, @unchecked Sendable {
    private var onData: ((Data) -> Void)?
    private var onFinish: ((Error?) -> Void)?
    private(set) var beginCount = 0
    private(set) var stopped = false

    func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void) {
      beginCount += 1
      self.onData = onData
      self.onFinish = onFinish
    }

    func stop() {
      stopped = true
      onData = nil
      onFinish = nil
    }

    /// Delivers only while running — a stopped session cannot deliver.
    func emit(_ bytes: Int) {
      guard !stopped else { return }
      onData?(Data(repeating: 0xAB, count: bytes))
    }

    func finish(error: Error? = nil) {
      guard !stopped else { return }
      onFinish?(error)
    }
  }

  /// The regression. A cancel/resume cycle is what a seek does, and the stream
  /// has to survive it.
  func testTheStreamSurvivesTheCancelResumeCycleThatASeekPerforms() throws {
    let producer = HonestProducer()
    let source = StreamingByteSource(
      producer: producer,
      estimatedBytes: 100_000,
      readWaitTimeout: 0.25
    )

    // The producer is connected lazily, inside the first read — so a read has
    // to come first or `emit` goes nowhere. Reading zero bytes at the origin
    // is served without waiting and does the connecting.
    _ = try? source.read(offset: 0, count: 0)
    producer.emit(1_000)
    XCTAssertEqual(try source.read(offset: 0, count: 100).count, 100)

    // What a seek does to the source it is seeking within.
    source.cancel()
    source.resume()

    XCTAssertFalse(producer.stopped, "a seek must not stop the producer")

    // The stream is still live, so bytes that had not arrived at seek time
    // still arrive — this is the read that used to time out and fall silent.
    producer.emit(1_000)
    XCTAssertEqual(
      try source.read(offset: 1_500, count: 100).count, 100,
      "a read past the seek-time write head must be served by the still-running stream"
    )
  }

  /// `cancel()` still has to do its own job: a read parked waiting for bytes
  /// that have not arrived must be let go, or a seek cannot proceed at all.
  func testCancelStillUnblocksAWaitingRead() {
    let producer = HonestProducer()
    let source = StreamingByteSource(
      producer: producer,
      estimatedBytes: 100_000,
      readWaitTimeout: 5
    )
    producer.emit(100)

    let unblocked = expectation(description: "the waiting read returned")
    DispatchQueue.global().async {
      // Far past the write head, so this parks on the condition variable.
      do {
        _ = try source.read(offset: 50_000, count: 100)
        XCTFail("the read should have been cancelled, not served")
      } catch {
        XCTAssertEqual(error as? ByteSourceError, .cancelled)
      }
      unblocked.fulfill()
    }

    // Long enough for the read above to be waiting rather than not yet started.
    Thread.sleep(forTimeInterval: 0.2)
    source.cancel()

    // Far below the 5s read timeout, so passing means `cancel` did it.
    wait(for: [unblocked], timeout: 1.0)
  }

  /// Bytes already received stay readable across a seek — a backward seek is
  /// the case this transport is supposed to serve well.
  func testAlreadyReceivedBytesRemainReadableAfterASeek() throws {
    let producer = HonestProducer()
    let source = StreamingByteSource(
      producer: producer,
      estimatedBytes: 100_000,
      readWaitTimeout: 0.25
    )
    _ = try? source.read(offset: 0, count: 0)
    producer.emit(4_000)

    source.cancel()
    source.resume()

    XCTAssertEqual(try source.read(offset: 0, count: 500).count, 500)
    XCTAssertEqual(try source.read(offset: 3_000, count: 500).count, 500)
  }

  /// Only the producer's own finish means the stream ended. A cancelled read
  /// is not an ending, and must not be reported as one.
  func testACancelledReadIsNotAnEnding() throws {
    let producer = HonestProducer()
    let source = StreamingByteSource(
      producer: producer,
      estimatedBytes: 100_000,
      readWaitTimeout: 0.25
    )
    _ = try? source.read(offset: 0, count: 0)
    producer.emit(1_000)

    source.cancel()
    source.resume()

    // Still the estimate, not a total derived from what happened to have
    // arrived when the seek came in. Reporting the latter would tell the
    // parser the file ends here, which is the shape of "the track ended
    // early" rather than "a read was interrupted".
    XCTAssertEqual(try source.totalBytes(), 100_000)
  }

  /**
   The length is a guess until the producer says otherwise.

   `AudioFileReader.readProc` reads this to decide whether an empty read at the
   reported length is the end of the file or a failure to deliver. While it is
   false the reported length is `duration × bitrate`, and treating that as the
   end is how a track ends itself early — the engine advances the queue on an
   end-of-file, so an estimate that undershoots plays the opening of every
   song in a queue and skips the rest.
   */
  func testTheLengthIsNotAuthoritativeUntilTheProducerFinishes() throws {
    let producer = HonestProducer()
    let source = StreamingByteSource(
      producer: producer,
      estimatedBytes: 100_000,
      readWaitTimeout: 0.25
    )
    _ = try? source.read(offset: 0, count: 0)
    producer.emit(1_000)

    XCTAssertFalse(source.isFinished, "still streaming: the length is an estimate")
    XCTAssertEqual(try source.totalBytes(), 100_000)

    producer.finish()

    XCTAssertTrue(source.isFinished, "the producer finished: the length is now known")
    XCTAssertEqual(
      try source.totalBytes(), 1_000,
      "once finished the real byte count is better than the estimate"
    )
  }
}
