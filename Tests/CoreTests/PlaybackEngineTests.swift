import XCTest
import AVFoundation
@testable import YuzicEngineCore

final class PlaybackEngineTests: XCTestCase {

  /**
   The crossfade trigger.

   Pure, and the one part of the engine worth testing directly — the rest is
   plumbing around a timer, and this is the decision the plumbing exists to
   make. `transitionDuration` decides how long a fade is; this decides when it
   starts, and the two are separate so each can be wrong on its own terms.
   */
  func testTransitionStartsExactlyAFadeBeforeTheEnd() {
    let begins = PlaybackEngine.shouldBeginTransition

    // Eight-second fade on a 240-second track: nothing at 231, everything from
    // 232 onward.
    XCTAssertFalse(begins(231, 240, 8))
    XCTAssertTrue(begins(232, 240, 8))
    XCTAssertTrue(begins(239, 240, 8))
  }

  func testNoTransitionWhenThereIsNoFade() {
    // transitionDuration returning zero is how every "cut, do not fade" rule is
    // expressed — a continuous stream, a segue, a manual skip. All of them
    // arrive here as a zero and must not start anything.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(positionSec: 239, durationSec: 240, transitionSec: 0))
  }

  func testNoTransitionWhenTheDurationIsUnknown() {
    // Live radio has no finish line to count backwards from.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(positionSec: 600, durationSec: 0, transitionSec: 8))
  }

  func testAFadeLongerThanTheTrackStartsImmediately() {
    // Clamping is transitionDuration's job, not this one's; if a long fade does
    // arrive here it should still behave sensibly rather than never firing.
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(positionSec: 0, durationSec: 5, transitionSec: 10))
  }

  // MARK: - Queue movement, driven through the real graph

  /// Hands out readers over an in-memory WAV, so the engine can be driven with
  /// no network and no audio hardware.
  private final class FixtureFactory: TrackReaderFactory {
    let data: Data
    private(set) var opened: [MediaId] = []
    init(data: Data) { self.data = data }

    func makeReader(for track: Track) throws -> AudioFileReader {
      opened.append(track.id)
      let source = CachedByteSource(fetcher: MemoryFetcher(data), windowBytes: 32 * 1024)
      return AudioFileReader(source: source)
    }

    private final class MemoryFetcher: ByteFetcher, @unchecked Sendable {
      let blob: Data
      init(_ blob: Data) { self.blob = blob }
      func contentLength() throws -> Int64 { Int64(blob.count) }
      func fetch(_ range: Range<Int64>) throws -> Data {
        let end = min(Int(range.upperBound), blob.count)
        guard Int(range.lowerBound) < end else { return Data() }
        return blob.subdata(in: Int(range.lowerBound)..<end)
      }
    }
  }

  private func song(_ id: String, durationSec: Double? = 3) -> Track {
    Track(id: id, uri: "file:///\(id).wav", title: id, durationSec: durationSec)
  }

  private func makeEngine() throws -> (PlaybackEngine, FixtureFactory, AudioGraph) {
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    return (PlaybackEngine(graph: graph, factory: factory), factory, graph)
  }

  func testPlayingOpensTheTrackAtTheStartIndex() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 1)
    try engine.play()

    XCTAssertEqual(factory.opened, ["b"])
    XCTAssertEqual(engine.state, .playing)
  }

  func testSkippingMovesTheQueueAndOpensTheNewTrack() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 0)
    try engine.play()
    try engine.skipToNext()

    XCTAssertEqual(factory.opened, ["a", "b"])
    XCTAssertEqual(engine.queue.activeIndex, 1)
  }

  func testSkippingPastTheEndFinishesRatherThanCrashing() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    var ended = false
    engine.onEvent = { if case .ended = $0 { ended = true } }
    try engine.skipToNext()

    XCTAssertTrue(ended)
    XCTAssertEqual(engine.state, .ended)
  }

  func testSkippingBackwardsBeforeTheStartDoesNothing() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    try engine.skipToPrevious()

    // Not an error, and not a wrap-around to the end of the queue.
    XCTAssertEqual(factory.opened, ["a"])
    XCTAssertEqual(engine.queue.activeIndex, 0)
  }

  func testTrackChangeReportsWhatWasListenedTo() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)

    var listened: Double?
    engine.onEvent = {
      if case .trackChanged(_, _, let seconds) = $0, let seconds { listened = seconds }
    }

    try engine.play()
    Thread.sleep(forTimeInterval: 0.2)
    try engine.skipToNext()

    // Without this a host scrobbling on "half the track or four minutes" has
    // nothing to measure once a crossfade is involved, because position never
    // reaches duration.
    XCTAssertNotNil(listened)
    XCTAssertGreaterThan(listened ?? 0, 0.1)
  }

  func testPauseAndResumeDoNotReopenTheTrack() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    engine.pause()
    XCTAssertEqual(engine.state, .paused)
    try engine.play()

    XCTAssertEqual(engine.state, .playing)
    XCTAssertEqual(factory.opened, ["a"], "resuming re-decoded the track from scratch")
  }

  func testStateGoesIdleOnStop() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    engine.stop()
    XCTAssertEqual(engine.state, .idle)
  }
}

final class SleepTimerTests: XCTestCase {

  func testFiresEarlyByTheFadeSoTheMusicHasGoneWhenAsked() {
    let expectation = expectation(description: "fired")
    var handedFade: TimeInterval?

    let timer = SleepTimer { fade in
      handedFade = fade
      expectation.fulfill()
    }
    // Half a second requested: the fade is clamped to half of it, so it fires
    // after 0.25s having asked for a 0.25s fade — the music is gone at 0.5s
    // rather than beginning to go then.
    timer.schedule(after: 0.5)

    wait(for: [expectation], timeout: 2)
    XCTAssertEqual(handedFade ?? 0, 0.25, accuracy: 0.05)
  }

  func testCancellingStopsItFiring() {
    let timer = SleepTimer { _ in XCTFail("a cancelled timer fired") }
    timer.schedule(after: 0.3)
    timer.cancel()
    XCTAssertNil(timer.firesAt)
    Thread.sleep(forTimeInterval: 0.5)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }

  func testRemainingCountsDown() {
    let timer = SleepTimer { _ in }
    timer.schedule(after: 60)
    let remaining = timer.remainingSeconds ?? 0
    XCTAssertGreaterThan(remaining, 58)
    XCTAssertLessThanOrEqual(remaining, 60)
  }

  func testSchedulingAgainReplacesTheFirst() {
    let timer = SleepTimer { _ in XCTFail("the replaced timer fired") }
    timer.schedule(after: 0.2)
    timer.schedule(after: 60)
    XCTAssertGreaterThan(timer.remainingSeconds ?? 0, 30)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  }
}
