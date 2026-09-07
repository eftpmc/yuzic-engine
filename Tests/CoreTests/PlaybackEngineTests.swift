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

  // MARK: - Which duration decides where a track ends

  /**
   A byte-derived duration that disagrees with the host loses.

   Reported from a real library: a song crossfaded into the next at about
   forty seconds instead of near its end. With a twelve-second fade that puts
   the reader's idea of the track at roughly fifty seconds — a transcoding
   endpoint declaring a byte length that maps to a fraction of the song. The
   host knows the real length from the server's metadata, and had it all along.
   */
  func testTheHostsDurationWinsWhenTheReaderIsWildlyShort() {
    // 52s of "file" against a 200s song: trust the song.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 52, declaredSec: 200), 200)
    // And the fade then starts where it should, not at forty seconds.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(positionSec: 40, durationSec: 200, transitionSec: 12))
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(positionSec: 188, durationSec: 200, transitionSec: 12))
  }

  /**
   The real case, with the real numbers.

   Movements — *Pulse*, 3:21 of FLAC at 1105 kbps, streamed over cellular where
   the forward-only path applies. The size handed to the parser was
   `duration × assumedBitrate`, and 320 kbps is about a third of what lossless
   costs — so 201.6s became 8 MB, which at the real byte rate reads as 58
   seconds. A twelve-second crossfade then began at 46.
   */
  func testTheAlbumThatReportedThis() {
    let declared = 201.6                     // Navidrome and the FLAC header agree
    let readerThought = 8_064_000.0 / (1_105_000.0 / 8)   // ≈ 58.4s

    let trusted = PlaybackEngine.referenceDuration(readerSec: readerThought, declaredSec: declared)
    XCTAssertEqual(trusted, declared)

    // Before: a fade beginning three quarters of the way through the track.
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(
      positionSec: 47, durationSec: readerThought, transitionSec: 12))
    // After: nothing until the song is actually ending.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(
      positionSec: 47, durationSec: trusted, transitionSec: 12))
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(
      positionSec: 190, durationSec: trusted, transitionSec: 12))
  }

  /// The assumption has to clear lossless, or the same fault returns by format.
  func testTheAssumedBitrateClearsLossless() {
    // A CD-rate FLAC is around 1100 kbps; 24/96 runs higher still.
    XCTAssertGreaterThan(HTTPTrackReaderFactory.assumedBitrate, 1_411_000,
                         "must exceed uncompressed CD audio, not just transcoded output")
  }

  func testTheReaderWinsWhenTheTwoAgree() {
    // Exact for a local file, and already corrected for encoder padding, so a
    // small disagreement should not throw away the more precise number.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 199.5, declaredSec: 200), 199.5)
  }

  func testAnUnknownHostDurationLeavesTheReaderInCharge() {
    // `nil` is "the host does not know", which is not zero.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 200, declaredSec: nil), 200)
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 200, declaredSec: 0), 200)
    // And a live stream, which has no finish line either way, still cannot fade.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 0, declaredSec: nil), 0)
  }

  func testAReaderThatKnowsNothingDefersToTheHost() {
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 0, declaredSec: 200), 200)
  }

  /**
   A skip opens the next track before silencing this one.

   `open()` on a remote track is a network round trip. The old order silenced
   the outgoing track and stopped it *first*, so the listener got dead air for
   however long the fetch took — reported from a car as several seconds of
   nothing on a skip, and absent on a downloaded playlist, where opening a
   local file is instant. That difference is the whole diagnosis.

   Audio renders on its own thread, so keeping the outgoing track alive across
   the open means it goes on playing. This asserts the ordering directly: at
   the moment the next reader is made, the voice must still be audible and the
   old playback must still be running.
   */
  func testASkipOpensTheNextTrackBeforeSilencingThisOne() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()

    var gainWhenNextWasOpened: Float?
    factory.onMakeReader = { id in
      // Only the skip's open, not the first track's.
      if id == "b" { gainWhenNextWasOpened = graph.activeVoice.gain.outputVolume }
    }

    try engine.skipToNext()

    XCTAssertEqual(gainWhenNextWasOpened, 1,
                   "the outgoing track must still be audible while the next one opens")
  }

  // MARK: - Volume, and the node it is allowed to touch

  /**
   Volume goes to the player, not to the gain node the crossfade ramps.

   This is the whole bug. `setVolume` wrote `gain.outputVolume` directly —
   the node `AudioGraph.setTrackGain` documents as belonging to fades, where
   "anything else written there is overwritten by the next ramp". So volume
   lasted until the next fade, skip or track change, and a skip taken during a
   crossfade left the voice stranded at whatever the abandoned ramp had
   reached, with the next volume command writing somewhere nothing would read
   again until the following track. Reported from a car: skip went silent, and
   the volume button then stopped the music entirely until the app restarted.
   */
  func testVolumeGoesToThePlayerNotTheFadeNode() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    engine.volume = 0.5

    XCTAssertEqual(graph.activeVoice.player.volume, 0.5, accuracy: 0.0001)
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1,
                   "the gain node belongs to the fade and must be left alone")
  }

  /// A skip used to discard volume, because the new track's gain was cut to 1.
  func testVolumeSurvivesASkip() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    engine.volume = 0.4

    try engine.skipToNext()

    XCTAssertEqual(graph.activeVoice.player.volume, 0.4, accuracy: 0.0001,
                   "the next track should play at the volume the user chose")
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1, "and at full fade gain")
  }

  /// Volume and replay gain are two multiplications, and both must survive.
  func testVolumeComposesWithReplayGain() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    engine.volume = 0.5
    let atFullVolume = graph.activeVoice.player.volume
    engine.volume = 1.0
    let expectedGain = graph.activeVoice.player.volume

    XCTAssertEqual(atFullVolume, expectedGain * 0.5, accuracy: 0.0001,
                   "halving volume should halve whatever replay gain decided")
  }

  func testVolumeIsClamped() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    engine.volume = 5
    XCTAssertEqual(graph.activeVoice.player.volume, 1, accuracy: 0.0001)
    engine.volume = -2
    XCTAssertEqual(graph.activeVoice.player.volume, 0, accuracy: 0.0001)
  }

  // MARK: - Repeat and the user's own skip

  /**
   A user skip obeys repeat, the same as an automatic advance does.

   `nextIndex` is where the queue's repeat rules live: under `.all` it wraps
   with `(activeIndex + 1) % count`. The automatic advance asks it. `skipToNext`
   did not — it computed `activeIndex + 1` directly, which on the last track is
   out of range, and `move` reads an index past the end as "the queue is
   finished" and stops playback.

   So the same queue, on the same track, in the same repeat mode, wrapped when
   the track ended by itself and stopped the music when the user pressed next.
   Android already asked `nextIndex` here; this is iOS catching up.
   */
  func testSkipToNextWrapsUnderRepeatAll() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 1)
    engine.queue.repeatMode = .all
    try engine.play()

    try engine.skipToNext()

    XCTAssertEqual(engine.queue.activeIndex, 0, "next on the last track should wrap to the first")
    XCTAssertNotEqual(engine.state, .idle, "wrapping should keep playing, not finish")
  }

  /**
   What `previous` means, which is not always "the previous track".

   iOS moved unconditionally: on the first track that computed -1, `move`
   rejected it, and the button did nothing at all. Android has had both rules
   since the model port — past three seconds, or on the first track, previous
   restarts. These are the same rule, now on both platforms.
   */
  func testPreviousRestartsPastThreeSeconds() {
    let action = PlaybackEngine.previousAction

    // Early in a track, previous means the previous track.
    XCTAssertEqual(action(0.5, 2), .goBack)
    XCTAssertEqual(action(3.0, 2), .goBack, "exactly three seconds is not yet past it")

    // Past the threshold it means "start this one again".
    XCTAssertEqual(action(3.1, 2), .restart)
    XCTAssertEqual(action(90, 2), .restart)
  }

  func testPreviousOnTheFirstTrackRestartsRatherThanDoingNothing() {
    // There is nothing before the first track, and the old behaviour computed
    // -1 and was silently rejected. Restarting is the only useful meaning.
    XCTAssertEqual(PlaybackEngine.previousAction(positionSec: 0.5, activeIndex: 0), .restart)
    XCTAssertEqual(PlaybackEngine.previousAction(positionSec: 90, activeIndex: 0), .restart)
  }

  /**
   Repeat-one is deliberately not wrapped onto a user skip.

   `nextIndex` under `.one` returns the *current* index, because that is what
   should play when this track ends. A person pressing next has asked to leave
   this track, so the skip advances rather than replaying it — the two callers
   want different answers from the same repeat mode, and that is why the skip
   cannot simply delegate to `nextIndex` in every case.
   */
  func testSkipToNextUnderRepeatOneStillAdvances() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    engine.queue.repeatMode = .one
    try engine.play()

    try engine.skipToNext()

    XCTAssertEqual(engine.queue.activeIndex, 1, "a person pressing next wants the next track, not this one again")
  }

  // MARK: - Queue movement, driven through the real graph

  /// Hands out readers over an in-memory WAV, so the engine can be driven with
  /// no network and no audio hardware.
  private final class FixtureFactory: TrackReaderFactory {
    let data: Data
    private(set) var opened: [MediaId] = []
    /// Called as a reader is made, so a test can look at the graph at exactly
    /// the moment the engine would be blocking on a network round trip.
    var onMakeReader: ((MediaId) -> Void)?
    init(data: Data) { self.data = data }

    func makeReader(for track: Track) throws -> TrackReader {
      opened.append(track.id)
      onMakeReader?(track.id)
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

  /**
   Resuming restores a voice something else faded away.

   The sleep timer fades to silence and pauses, which leaves the gain at zero.
   Resuming without restoring it plays a track nobody can hear while the
   progress bar advances normally — and that reads as a broken player rather
   than a sleep timer that worked.
   */
  func testResumingAfterAFadeToSilenceIsAudible() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    // What the sleep timer leaves behind.
    graph.cut(graph.activeVoice, to: 0)
    engine.pause()
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 0)

    try engine.play()
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1)
  }

  /**
   The play path reconnects the voice it actually plays on.

   `makeEngine` builds graph and fixture both at 44.1kHz, so the two rates
   agree and no mismatch can arise — which is exactly why every other test here
   passed while the direct-play path was reconnecting the wrong voice. This one
   pairs a 44.1kHz file with the 48kHz graph real hardware usually gives you.

   The failure is audible: the node reads the reader's 44.1kHz buffers as
   48kHz ones, so the track plays 8.8% fast and about 1.5 semitones sharp. The
   position is wrong by the same ratio — `playerTime.sampleTime` counts in the
   connection's frames while `AudioFileReader.sampleRate` reports the file's —
   so the playhead runs ahead and the crossfade starts early.
   */
  func testPlayingReconnectsTheVoiceItPlaysOn() throws {
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 48_000)
    try graph.startOffline(sampleRate: 48_000)
    let engine = PlaybackEngine(graph: graph, factory: factory)

    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    XCTAssertEqual(
      graph.activeVoice.player.outputFormat(forBus: 0).sampleRate, 44_100,
      "the playing voice must carry the file's rate, or its position is wrong"
    )
  }

  // MARK: - The system taking the audio away

  /**
   Resuming after an interruption, which is only ever conditional.

   Two things have to be true: the system has to say the interrupting app is
   finished with the session, and the pause has to have been *ours*. Resuming
   playback the listener had already stopped — because a call arrived while
   the player sat paused — starts music in someone's ear for no reason.

   The wiring around this cannot be tested without a device; the rule can, and
   the rule is the part that is easy to get wrong.
   */
  func testResumesOnlyWhatItPausedItself() {
    XCTAssertTrue(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: true, systemSaysResume: true))
  }

  func testDoesNotResumePlaybackTheListenerHadAlreadyStopped() {
    XCTAssertFalse(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: false, systemSaysResume: true))
  }

  /// The system withholding `.shouldResume` is a decision, not an omission —
  /// it is how it says another app is still using the session.
  func testDoesNotResumeWhenTheSystemSaysNotTo() {
    XCTAssertFalse(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: true, systemSaysResume: false))
    XCTAssertFalse(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: false, systemSaysResume: false))
  }

  func testPlayingOpensTheTrackAtTheStartIndex() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 1)
    try engine.play()

    XCTAssertEqual(factory.opened, ["b"])
  }

  /**
   `play()` means "asked to play", not "playing".

   `TrackPlayback.start` dispatches the decode and returns; the decode blocks
   on the network. The engine used to announce `.playing` right there, which
   is why a slow connection could leave a pause button showing over a
   position frozen at 0:00 with nothing able to say it was still waiting.

   So the state stays `.buffering` until a buffer actually reaches the node.
   This test asserts both halves — the state immediately after the call, and
   the transition once audio exists — because the first without the second
   would pass just as well if playback never started at all.
   */
  func testStateIsBufferingUntilAudioActuallyStarts() throws {
    let (engine, _, _) = try makeEngine()

    var seen: [PlaybackEngine.PlaybackState] = []
    engine.onEvent = { if case .stateChanged(let state) = $0 { seen.append(state) } }

    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    XCTAssertEqual(engine.state, .buffering, "announced playing before any audio was scheduled")

    let playing = expectation(description: "reaches playing once a buffer is scheduled")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    XCTAssertEqual(engine.state, .playing)
    XCTAssertEqual(seen, [.buffering, .playing], "the host should see the wait, then the start")
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

  /**
   Paused time is not listened time.

   `previousListenedSec` is what a host judges a scrobble threshold against —
   "half the track, or four minutes" — so counting the pause submits a play to
   Last.fm and ListenBrainz for music nobody heard. A track paused overnight
   and skipped in the morning would clear any threshold there is.

   The clock is injected rather than slept through, so the pause here is an
   hour long and the test still takes no time. Sleeping would only have let me
   test a pause of a few hundred milliseconds, which is precisely the size of
   pause that does not matter.
   */
  func testAPauseDoesNotCountAsListening() throws {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    let engine = PlaybackEngine(graph: graph, factory: factory, now: { clock })

    engine.setQueue([song("a"), song("b")], startIndex: 0)

    var listened: Double?
    engine.onEvent = {
      if case .trackChanged(_, _, let seconds) = $0, let seconds { listened = seconds }
    }

    try engine.play()
    clock.addTimeInterval(30)      // listened
    engine.pause()
    clock.addTimeInterval(3600)    // did not listen
    try engine.play()
    clock.addTimeInterval(10)      // listened
    try engine.skipToNext()

    XCTAssertEqual(listened ?? 0, 40, accuracy: 0.001,
                   "the hour spent paused was counted as listening")
  }

  /// Pausing twice must not bank the same stretch twice.
  func testPausingAnAlreadyPausedTrackDoesNotDoubleCount() throws {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    let engine = PlaybackEngine(graph: graph, factory: factory, now: { clock })

    engine.setQueue([song("a"), song("b")], startIndex: 0)
    var listened: Double?
    engine.onEvent = {
      if case .trackChanged(_, _, let seconds) = $0, let seconds { listened = seconds }
    }

    try engine.play()
    clock.addTimeInterval(20)
    engine.pause()
    clock.addTimeInterval(5)
    engine.pause()
    try engine.skipToNext()

    XCTAssertEqual(listened ?? 0, 20, accuracy: 0.001)
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
