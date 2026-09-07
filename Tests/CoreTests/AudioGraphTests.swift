import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 The graph, rendered offline.

 `AVAudioEngine`'s manual rendering mode runs the whole chain with no audio
 hardware, so this is the first thing in the project that establishes sound
 actually comes out — every test before it proved bytes were decoded, not that
 they reached an output.

 What is checked is amplitude rather than exact samples: the point is that audio
 is present, that gain does what it says, and that a crossfade does not dip in
 the middle. Bit-exactness would only pin down the resampler's implementation.
 */
final class AudioGraphTests: XCTestCase {

  /// RMS of the left channel — a single number for "how loud is this".
  private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) {
      let sample = data[0][index]
      sum += sample * sample
    }
    return sqrt(sum / Float(buffer.frameLength))
  }

  /// A steady tone, as a buffer the graph can be handed directly.
  private func tone(seconds: Double, sampleRate: Double = AudioGraph.fixedSampleRate,
                    amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    var phase = 0.0
    for index in 0..<Int(frames) {
      phase += 2.0 * Double.pi * 440.0 / sampleRate
      let sample = amplitude * Float(sin(phase))
      buffer.floatChannelData![0][index] = sample
      buffer.floatChannelData![1][index] = sample
    }
    return buffer
  }

  /**
   Which voice a reconnect lands on.

   This is the assertion that would have caught a real bug: the direct-play
   path called `reconnectIdleVoice` and then started the track on the *active*
   voice, so the file's rate was applied to the one node that was not about to
   be used. A 44.1kHz track over a 48kHz connection then plays 8.8% fast and
   about 1.5 semitones sharp — the node reads the reader's buffers as its own
   rate — and reports its position wrong by the same ratio, because
   `playerTime.sampleTime` counts in the connection's frames while the reader
   reports the file's.

   Checking the connection's rate is the cheapest way to pin that: the audible
   defect and the wrong number have this single cause, so the rate is the thing
   worth asserting rather than either symptom.
   */
  func testReconnectTargetsTheVoiceItIsGiven() throws {
    let graph = AudioGraph()
    try graph.startOffline()

    graph.reconnect(graph.activeVoice, toSourceRate: 44_100)

    XCTAssertEqual(graph.activeVoice.player.outputFormat(forBus: 0).sampleRate, 44_100)
    XCTAssertEqual(
      graph.idleVoice.player.outputFormat(forBus: 0).sampleRate, AudioGraph.fixedSampleRate,
      "reconnecting one voice must not disturb the other"
    )
  }

  /// The crossfade path's variant, which really does want the idle voice —
  /// pinned so that fixing the direct-play caller cannot quietly redirect it.
  func testIdleReconnectLeavesTheActiveVoiceAlone() throws {
    let graph = AudioGraph()
    try graph.startOffline()

    graph.reconnectIdleVoice(toSourceRate: 44_100)

    XCTAssertEqual(graph.idleVoice.player.outputFormat(forBus: 0).sampleRate, 44_100)
    XCTAssertEqual(
      graph.activeVoice.player.outputFormat(forBus: 0).sampleRate, AudioGraph.fixedSampleRate
    )
  }

  func testAudioActuallyReachesTheOutput() throws {
    let graph = AudioGraph()
    try graph.startOffline()

    graph.activeVoice.player.scheduleBuffer(tone(seconds: 1))
    graph.activeVoice.player.play()

    let rendered = try graph.renderOffline(frames: 4096)
    XCTAssertEqual(rendered.frameLength, 4096)
    // Silence here would mean the chain is wired but mute — which is exactly
    // the failure a compile-only check cannot see.
    XCTAssertGreaterThan(rms(rendered), 0.1)
  }

  func testAnIdleVoiceIsSilent() throws {
    let graph = AudioGraph()
    try graph.startOffline()

    // Only the active voice is at full gain; the other is waiting at zero, so
    // scheduling into it must produce nothing until it is faded up.
    graph.idleVoice.player.scheduleBuffer(tone(seconds: 1))
    graph.idleVoice.player.play()

    let rendered = try graph.renderOffline(frames: 4096)
    XCTAssertLessThan(rms(rendered), 0.001)
  }

  func testGainIsHonoured() throws {
    let graph = AudioGraph()
    try graph.startOffline()
    graph.activeVoice.player.scheduleBuffer(tone(seconds: 1))
    graph.activeVoice.player.play()

    let full = rms(try graph.renderOffline(frames: 4096))

    graph.activeVoice.gain.outputVolume = 0.5
    // A mixer smooths volume changes rather than stepping them — measured
    // immediately, this reads about 0.76 because the gain is still gliding.
    // That smoothing is wanted, not worked around: it is what keeps the
    // stepped crossfade in `fade()` free of zipper noise. So let it settle.
    _ = try graph.renderOffline(frames: 8192)
    let half = rms(try graph.renderOffline(frames: 4096))

    XCTAssertEqual(half / full, 0.5, accuracy: 0.05)
  }

  /**
   A cut takes effect without a run loop spinning.

   It used to run a 15ms fade, which meant it depended on a timer, which meant
   that anywhere no run loop was running — offline rendering here, and any
   caller on a queue in production — the cut simply never happened. Silent, and
   only in the places hardest to look at.
   */
  func testCutTakesEffectImmediately() throws {
    let graph = AudioGraph()
    try graph.startOffline()
    graph.cut(graph.activeVoice, to: 0.25)
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 0.25)
  }

  /**
   Replay gain and a fade are two multiplications in one path, not one setting
   fighting another.

   This is the whole reason track gain is applied to the player node and fades
   to the voice's mixer. Written on the same node, every fade ramp would erase
   the loudness adjustment on its way past — silently, and only for tracks that
   happened to be crossfaded.
   */
  func testTrackGainAndFadeMultiplyRatherThanClobber() throws {
    let graph = AudioGraph()
    try graph.startOffline()
    graph.activeVoice.player.scheduleBuffer(tone(seconds: 2))
    graph.activeVoice.player.play()

    let full = rms(try graph.renderOffline(frames: 4096))

    graph.setTrackGain(graph.activeVoice, to: 0.5)
    graph.cut(graph.activeVoice, to: 0.5)
    _ = try graph.renderOffline(frames: 8192)   // let the mixer's glide settle
    let both = rms(try graph.renderOffline(frames: 4096))

    XCTAssertEqual(both / full, 0.25, accuracy: 0.03)
  }

  /**
   The reason the whole project exists, measured.

   Two voices playing at once, one fading out and one fading in. The thing that
   must not happen is a dip at the crossover: two *linear* ramps crossing at
   their midpoint sum to about half amplitude, which is audible as a hole in
   the middle of the fade. Equal-power shaping is what avoids it.
   */
  /**
   The fade curve itself, which the RMS test below cannot reach.

   `testCrossfadeDoesNotDipInTheMiddle` sets `outputVolume` by hand to
   `sqrt(0.5)` and renders. That checks the *mixer* sums equal-power gains
   without dipping — a real property, and one that holds no matter what curve
   `fade()` computes. It passed throughout a period when the fade-out was
   inverted, which is the argument for testing the arithmetic directly.

   The bug it missed: an outgoing track that rose from silence over the fade
   and was then cut to zero at the end. Audible as the outgoing song dipping
   sharply, the incoming one arriving at full volume with nothing masking it,
   and then the outgoing one growing *louder* through the fade — reported from
   a real build before any test caught it.
   */
  func testAFadeOutFallsAndAFadeInRises() {
    XCTAssertEqual(AudioGraph.fadeVolume(from: 1, to: 0, position: 0), 1, accuracy: 0.001)
    XCTAssertEqual(AudioGraph.fadeVolume(from: 1, to: 0, position: 1), 0, accuracy: 0.001)
    XCTAssertEqual(AudioGraph.fadeVolume(from: 0, to: 1, position: 0), 0, accuracy: 0.001)
    XCTAssertEqual(AudioGraph.fadeVolume(from: 0, to: 1, position: 1), 1, accuracy: 0.001)
  }

  /// Monotonic, which is the property the inverted curve broke most audibly.
  func testAFadeOutNeverGetsLouder() {
    var previous = AudioGraph.fadeVolume(from: 1, to: 0, position: 0)
    for step in 1...50 {
      let volume = AudioGraph.fadeVolume(from: 1, to: 0, position: Float(step) / 50)
      XCTAssertLessThanOrEqual(volume, previous, "the fade-out rose at step \(step)")
      previous = volume
    }
  }

  /**
   The contract in one line: the two halves sum to constant power.

   This is what "equal power" means and what stops the crossover dipping.
   Checked across the whole fade rather than only at the midpoint, because the
   inverted curve happened to be symmetric about it.
   */
  func testTheTwoHalvesOfACrossfadeSumToConstantPower() {
    for step in 0...20 {
      let position = Float(step) / 20
      let rising = AudioGraph.fadeVolume(from: 0, to: 1, position: position)
      let falling = AudioGraph.fadeVolume(from: 1, to: 0, position: position)
      XCTAssertEqual(rising * rising + falling * falling, 1.0, accuracy: 0.001,
                     "power was not constant at \(position)")
    }
  }

  /// A partial fade — the sleep timer fades to silence from wherever it is.
  func testAPartialFadeStaysWithinItsEndpoints() {
    let volume = AudioGraph.fadeVolume(from: 0.5, to: 0, position: 0.5)
    XCTAssertLessThan(volume, 0.5)
    XCTAssertGreaterThan(volume, 0)
  }

  /// Positions outside 0...1 are clamped rather than producing a NaN from
  /// `sqrt` of a negative.
  func testPositionsOutsideTheFadeAreClamped() {
    XCTAssertEqual(AudioGraph.fadeVolume(from: 1, to: 0, position: 1.5), 0, accuracy: 0.001)
    XCTAssertEqual(AudioGraph.fadeVolume(from: 1, to: 0, position: -0.5), 1, accuracy: 0.001)
  }

  func testCrossfadeDoesNotDipInTheMiddle() throws {
    let graph = AudioGraph()
    try graph.startOffline()

    graph.voiceA.player.scheduleBuffer(tone(seconds: 2))
    graph.voiceB.player.scheduleBuffer(tone(seconds: 2))
    graph.voiceA.player.play()
    graph.voiceB.player.play()

    // Mid-crossfade, by construction: equal power on both sides.
    graph.voiceA.gain.outputVolume = sqrt(0.5)
    graph.voiceB.gain.outputVolume = sqrt(0.5)
    let middle = rms(try graph.renderOffline(frames: 4096))

    // And either end of the fade, one voice at full.
    graph.voiceA.gain.outputVolume = 1
    graph.voiceB.gain.outputVolume = 0
    let ends = rms(try graph.renderOffline(frames: 4096))

    // Within a couple of dB. Linear ramps would put the middle at roughly half
    // of this, which is the dip.
    XCTAssertEqual(middle / ends, 1.0, accuracy: 0.25)
  }

  func testEqualizerIsBypassedWhenFlat() throws {
    let graph = AudioGraph()
    try graph.startOffline()
    graph.activeVoice.player.scheduleBuffer(tone(seconds: 1))
    graph.activeVoice.player.play()

    let before = rms(try graph.renderOffline(frames: 4096))
    // An untouched EQ should cost nothing and change nothing.
    graph.setEqualizer(bands: [])
    let after = rms(try graph.renderOffline(frames: 4096))

    XCTAssertEqual(after, before, accuracy: 0.02)

    // The assertion the name promises, and the one the RMS check above cannot
    // make: a flat parametric EQ sounds identical to a bypassed one, so
    // comparing rendered audio proves the audio is unharmed and says nothing
    // about whether the unit is in the chain. Found by deleting the bypass
    // guard and watching the whole suite stay green.
    XCTAssertTrue(graph.isEqualizerBypassed, "a flat equalizer was left in the chain")
  }

  /// And the other direction: a real curve must not be bypassed.
  func testEqualizerIsEngagedWhenABandIsSet() throws {
    let graph = AudioGraph()
    try graph.startOffline()

    graph.setEqualizer(bands: [(frequency: 1000, gainDb: 6, q: 1)])
    XCTAssertFalse(graph.isEqualizerBypassed)

    graph.setEqualizer(bands: [(frequency: 1000, gainDb: 0, q: 1)])
    XCTAssertTrue(graph.isEqualizerBypassed, "a curve of all zeroes is flat")
  }

  func testEqualizerChangesTheSound() throws {
    let graph = AudioGraph()
    try graph.startOffline()
    graph.activeVoice.player.scheduleBuffer(tone(seconds: 2))
    graph.activeVoice.player.play()

    let flat = rms(try graph.renderOffline(frames: 8192))

    // A deep cut centred on the tone should audibly reduce it. This is the
    // equalizer yuzic has had a UI for and no working implementation of.
    graph.setEqualizer(bands: [(frequency: 440, gainDb: -24, q: 1.0)])
    let cut = rms(try graph.renderOffline(frames: 8192))

    XCTAssertLessThan(cut, flat * 0.8)
  }

  // MARK: - the scheduler, end to end

  func testDecodedAudioFlowsFromAReaderIntoTheGraph() throws {
    // A real encoded file, through the cache, the reader, the scheduler and
    // out of the graph — the whole chain in one test.
    let fixture = try EncodedFixture.wav(seconds: 3)
    let source = CachedByteSource(fetcher: fixture.fetcher, windowBytes: 32 * 1024)
    let reader = AudioFileReader(source: source)
    try reader.open()

    let graph = AudioGraph(sampleRate: reader.sampleRate)
    try graph.startOffline(sampleRate: reader.sampleRate)

    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    try playback.start()

    // Give the decode queue a moment to get buffers scheduled.
    let deadline = Date().addingTimeInterval(2)
    while graph.activeVoice.player.isPlaying == false && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    Thread.sleep(forTimeInterval: 0.3)

    let rendered = try graph.renderOffline(frames: 8192)
    XCTAssertGreaterThan(rms(rendered), 0.05, "decoded audio did not reach the output")
    playback.stop()
  }
}

/// Shared fixture builder — a real encoded file, in memory, behind a fetcher.
enum EncodedFixture {
  struct Fixture { let data: Data; let fetcher: ByteFetcher }

  static func wav(seconds: Int) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-engine-graph-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tone-\(seconds).wav")

    if !FileManager.default.fileExists(atPath: url.path) {
      let sampleRate = 44_100.0
      var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
      buffer.frameLength = AVAudioFrameCount(sampleRate)
      var phase = 0.0
      for _ in 0..<seconds {
        for index in 0..<Int(sampleRate) {
          phase += 2.0 * Double.pi * 440.0 / sampleRate
          let sample = Float(0.5 * sin(phase))
          buffer.floatChannelData![0][index] = sample
          buffer.floatChannelData![1][index] = sample
        }
        try writer!.write(from: buffer)
      }
      writer = nil   // finalises the header
    }

    let data = try Data(contentsOf: url)
    return Fixture(data: data, fetcher: MemoryFetcher(data))
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

/// The scheduler's side of cancellation: what a seek does to a decode thread
/// that is parked on the network.
final class TrackPlaybackCancellationTests: XCTestCase {

  /**
   A seek must not wait for the read it is interrupting.

   This is the end-to-end half of the cancellation work: `CachedByteSource` and
   `HTTPByteFetcher` can each abandon a read on demand, but until `stop` called
   through to them, a producer parked on the network stayed parked — and the
   seek that wanted the reader had to wait it out.

   Waiting is also what makes it more than a slow seek. `PlaybackEngine.seek`
   builds a new `TrackPlayback` over the *same* reader, and `AudioFileReader`
   is not thread-safe, so returning early would put two threads inside one
   reader with the new one seeking it.
   */
  func testStopAndWaitReturnsWithoutWaitingOutABlockedRead() throws {
    let fixture = try EncodedFixture.wav(seconds: 3)
    let gate = GatedFetcher(fixture.fetcher)
    let source = CachedByteSource(fetcher: gate, windowBytes: 32 * 1024)
    let reader = AudioFileReader(source: source)
    try reader.open()

    let graph = AudioGraph(sampleRate: reader.sampleRate)
    try graph.startOffline(sampleRate: reader.sampleRate)

    // Stall everything the decode thread asks for from here on, the way a
    // connection that has gone quiet does.
    gate.stall()

    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    try playback.start()

    XCTAssertEqual(gate.blocked.wait(timeout: .now() + 5), .success,
                   "the decode thread never reached a blocking read")

    let started = Date()
    playback.stopAndWait()
    let waited = Date().timeIntervalSince(started)
    XCTAssertLessThan(waited, 2, "stopAndWait waited out the read instead of cancelling it")

    // And the reader is left usable, because a seek is about to reuse this
    // exact one. A cancelled source that was never resumed would refuse.
    gate.release()
    try reader.seek(toFrame: 0)
    XCTAssertNotNil(try reader.read(frames: 1024))
  }
}

/**
 Wraps a fetcher and parks in `fetch` on command, releasing only on a cancel.

 The point is to hold the producer inside a read at the moment the test calls
 `stopAndWait`, which is the situation the real code hits on a slow network and
 cannot otherwise be arranged deterministically.
 */
private final class GatedFetcher: ByteFetcher, @unchecked Sendable {
  private let inner: ByteFetcher
  private let lock = NSLock()
  private var stalling = false
  private var cancelled = false

  /// Signalled once the producer is actually parked, so the test does not race it.
  let blocked = DispatchSemaphore(value: 0)
  private let gate = DispatchSemaphore(value: 0)

  init(_ inner: ByteFetcher) { self.inner = inner }

  func stall() { lock.lock(); stalling = true; lock.unlock() }

  func release() {
    lock.lock(); stalling = false; cancelled = false; lock.unlock()
    gate.signal()
  }

  func contentLength() throws -> Int64 { try inner.contentLength() }

  func fetch(_ range: Range<Int64>) throws -> Data {
    lock.lock(); let stall = stalling; lock.unlock()
    if stall {
      blocked.signal()
      gate.wait()
      lock.lock(); let wasCancelled = cancelled; lock.unlock()
      if wasCancelled { throw ByteSourceError.cancelled }
    }
    return try inner.fetch(range)
  }

  func cancel() {
    lock.lock(); cancelled = true; lock.unlock()
    gate.signal()
  }

  func resume() { lock.lock(); cancelled = false; lock.unlock() }
}

/// The speed control: what it accepts, and that adding it to the chain did not
/// quietly break the chain.
final class AudioGraphSpeedTests: XCTestCase {

  private func makeGraph() throws -> AudioGraph {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    return graph
  }

  func testDefaultsToUntouchedAndBypassed() throws {
    let graph = try makeGraph()
    XCTAssertEqual(graph.currentSpeed, 1.0)
  }

  func testAbsurdRatesAreClampedRatherThanHonoured() throws {
    let graph = try makeGraph()
    // AVAudioUnitTimePitch would accept both of these and produce something
    // nobody could listen to. A host asking for them has a bug.
    graph.setSpeed(100)
    XCTAssertEqual(graph.currentSpeed, 4.0)
    graph.setSpeed(0.001)
    XCTAssertEqual(graph.currentSpeed, 0.25)
  }

  func testOrdinaryRatesPassThrough() throws {
    let graph = try makeGraph()
    for rate in [Float(0.5), 0.75, 1.5, 2.0] {
      graph.setSpeed(rate)
      XCTAssertEqual(graph.currentSpeed, rate, accuracy: 0.0001)
    }
  }

  /// The regression that matters: a new node between the EQ and the output is
  /// a chance to disconnect the graph, and a disconnected graph is silent
  /// rather than broken-looking.
  func testAudioStillReachesTheOutputAtDoubleSpeed() throws {
    let fixture = try EncodedFixture.wav(seconds: 3)
    let source = CachedByteSource(fetcher: fixture.fetcher, windowBytes: 32 * 1024)
    let reader = AudioFileReader(source: source)
    try reader.open()

    let graph = AudioGraph(sampleRate: reader.sampleRate)
    try graph.startOffline(sampleRate: reader.sampleRate)
    graph.setSpeed(2.0)

    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    try playback.start()

    let deadline = Date().addingTimeInterval(2)
    while graph.activeVoice.player.isPlaying == false && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    Thread.sleep(forTimeInterval: 0.3)

    let rendered = try graph.renderOffline(frames: 8192)
    XCTAssertGreaterThan(rms(rendered), 0.05, "the speed node swallowed the audio")
    playback.stop()
  }

  private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<count { sum += data[0][index] * data[0][index] }
    return (sum / Float(count)).squareRoot()
  }
}
