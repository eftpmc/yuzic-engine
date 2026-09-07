import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 A read that fails is not the end of the track.

 `TrackReader.read` returns nil at the end of the stream and throws when it
 cannot read — the protocol says so in as many words. `TrackPlayback` used to
 collapse the two: a throw set `reachedEnd`, so a dropped connection was
 reported to the engine as a track finishing normally, and the engine advanced.

 Reported from a car on cellular: lossless tracks "skipping" part-way through
 at a different point every time — 57s, 30s, 20s — while the app displayed the
 correct total length throughout, and never once on a downloaded playlist.
 Nothing threw where anyone could see it, because the failure was delivered as
 a success.
 */
final class TrackPlaybackFailureTests: XCTestCase {

  private struct ReadFailed: Error {}

  /// Hands out `successes` buffers, then behaves as told: throwing, or ending.
  private final class ScriptedReader: TrackReader {
    enum Ending { case throwsForever, endsCleanly }

    let totalFrames: Int64 = 44_100 * 60
    let sampleRate: Double = 44_100
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let ending: Ending
    private var remaining: Int
    private(set) var reads = 0

    init(successes: Int, then ending: Ending) {
      self.remaining = successes
      self.ending = ending
    }

    func open() throws {}
    func seek(toFrame frame: Int64) throws {}
    func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 { 0 }
    func cancelPendingReads() {}
    func resumePendingReads() {}

    func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
      reads += 1
      if remaining > 0 {
        remaining -= 1
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
      }
      switch ending {
      case .throwsForever: throw ReadFailed()
      case .endsCleanly: return nil
      }
    }
  }

  /// The graph has to outlive the playback — a voice whose graph has gone
  /// takes its engine with it, and `scheduleBuffer` trips an assertion.
  private var graph: AudioGraph?

  private func voice() throws -> AudioGraph.Voice {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    self.graph = graph
    return graph.activeVoice
  }

  override func tearDown() {
    graph = nil
    super.tearDown()
  }

  func testAFailingReadReportsFailureAndNotTheEndOfTheTrack() throws {
    let reader = ScriptedReader(successes: 2, then: .throwsForever)
    let playback = TrackPlayback(reader: reader, voice: try voice())

    var endedCalled = false
    let failed = expectation(description: "read failure reported")
    playback.onEndOfTrack = { endedCalled = true }
    playback.onReadFailed = { _ in failed.fulfill() }

    try playback.start(atFrame: 0)
    wait(for: [failed], timeout: 10)

    XCTAssertFalse(endedCalled,
                   "a lost stream must not be reported as the track finishing")
  }

  func testAFailingReadIsRetriedBeforeBeingGivenUpOn() throws {
    let reader = ScriptedReader(successes: 1, then: .throwsForever)
    let playback = TrackPlayback(reader: reader, voice: try voice())

    let failed = expectation(description: "gave up eventually")
    playback.onReadFailed = { _ in failed.fulfill() }
    try playback.start(atFrame: 0)
    wait(for: [failed], timeout: 10)

    // One good read, then the failing one and its retries. A single attempt
    // would abandon a track for a blip that the next request would have served.
    XCTAssertGreaterThan(reader.reads, 1 + TrackPlayback.readRetries,
                         "the failing read should have been retried, not abandoned")
  }

  /**
   Running out of file is not a failure.

   The end-of-track *callback* is not asserted here: it waits for every
   scheduled buffer to play out, and an offline graph never plays them, so a
   test at this level cannot see it. Natural completion advancing the queue is
   covered at the engine level. What matters here is the other half — that a
   clean end is not mistaken for the error case, which is the mirror of the
   bug this file is about.
   */
  func testACleanEndIsNotReportedAsAFailure() throws {
    let reader = ScriptedReader(successes: 2, then: .endsCleanly)
    let playback = TrackPlayback(reader: reader, voice: try voice())

    var failedCalled = false
    playback.onReadFailed = { _ in failedCalled = true }
    try playback.start(atFrame: 0)

    // Long enough that the retry ladder would have run to its end and reported.
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    XCTAssertFalse(failedCalled, "running out of file is not a failure")
    XCTAssertEqual(reader.reads, 3, "two buffers, then the nil that ends it")
  }
}
