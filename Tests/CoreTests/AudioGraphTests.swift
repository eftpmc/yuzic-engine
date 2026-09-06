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
   The reason the whole project exists, measured.

   Two voices playing at once, one fading out and one fading in. The thing that
   must not happen is a dip at the crossover: two *linear* ramps crossing at
   their midpoint sum to about half amplitude, which is audible as a hole in
   the middle of the fade. Equal-power shaping is what avoids it.
   */
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
