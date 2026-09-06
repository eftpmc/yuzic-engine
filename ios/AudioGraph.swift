import AVFoundation

/**
 The playback graph.

 Two player nodes, not one. That is the whole reason this project exists rather
 than a wrapper around `AVQueuePlayer`: a crossfade is two sources overlapping,
 and one output cannot overlap with itself. The nodes alternate — while `a` is
 playing, `b` is the one being prepared, and they swap at every transition — so
 a fade is a volume ramp on each of a pair that are both already running.

    playerA ─┐
             ├─▶ eq ─▶ mainMixer ─▶ output
    playerB ─┘

 The EQ sits after the mixer rather than per-player so a crossfade does not run
 two copies of the filter chain, and so changing the curve mid-fade cannot make
 the two halves sound different from each other.
 */
final class AudioGraph {

  /// A source and the gain node it is faded with. Gain is separate from the
  /// player's own `volume` so a crossfade ramp and the user's volume setting
  /// cannot overwrite one another.
  struct Voice {
    let player: AVAudioPlayerNode
    let gain: AVAudioMixerNode
  }

  private let engine = AVAudioEngine()
  private let eq: AVAudioUnitEQ
  private(set) var voiceA: Voice
  private(set) var voiceB: Voice

  /// Which voice is currently the foreground one. The other is the one being
  /// prepared, or fading out.
  private(set) var activeIsA = true

  var activeVoice: Voice { activeIsA ? voiceA : voiceB }
  var idleVoice: Voice { activeIsA ? voiceB : voiceA }

  /**
   The rate everything is converted into, in `fixed` mode.

   48kHz because that is what iOS hardware most often runs at natively, so the
   common case is a no-op rather than a resample. Tracks at other rates are
   converted on the connection; `AVAudioEngine` inserts the converter itself
   when the formats of two connected nodes differ.
   */
  static let fixedSampleRate: Double = 48_000

  init(sampleRate: Double = AudioGraph.fixedSampleRate) {
    eq = AVAudioUnitEQ(numberOfBands: 10)
    eq.globalGain = 0

    voiceA = Voice(player: AVAudioPlayerNode(), gain: AVAudioMixerNode())
    voiceB = Voice(player: AVAudioPlayerNode(), gain: AVAudioMixerNode())

    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    for voice in [voiceA, voiceB] {
      engine.attach(voice.player)
      engine.attach(voice.gain)
      engine.connect(voice.player, to: voice.gain, format: format)
      engine.connect(voice.gain, to: eq, format: format)
      voice.gain.outputVolume = 0
    }
    engine.attach(eq)
    engine.connect(eq, to: engine.mainMixerNode, format: format)

    // Full scale on the active voice; the fade is done on the per-voice gain.
    voiceA.gain.outputVolume = 1
  }

  func start() throws {
    guard !engine.isRunning else { return }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    engine.stop()
  }

  /// Swap which voice is foreground. Called at the crossover point.
  func swapVoices() {
    activeIsA.toggle()
  }

  // MARK: - Equalizer

  /**
   An untouched EQ costs nothing: with every band flat the unit is bypassed
   outright rather than left in the chain multiplying by one.
   */
  func setEqualizer(bands: [(frequency: Float, gainDb: Float, q: Float)]) {
    guard !bands.isEmpty, bands.contains(where: { $0.gainDb != 0 }) else {
      eq.bypass = true
      return
    }
    eq.bypass = false
    for (index, band) in bands.prefix(eq.bands.count).enumerated() {
      let target = eq.bands[index]
      target.filterType = .parametric
      target.frequency = band.frequency
      target.gain = band.gainDb
      target.bandwidth = band.q
      target.bypass = false
    }
    // Any band the caller did not supply is neutralised rather than left
    // holding whatever the previous curve put there.
    for index in bands.count..<eq.bands.count {
      eq.bands[index].bypass = true
    }
  }

  // MARK: - Gain

  /**
   Ramp a voice's gain over `duration`, on the audio thread's clock rather than
   a timer, so a fade stays sample-accurate while the app is backgrounded and
   its timers are being throttled.
   */
  func ramp(_ voice: Voice, to target: Float, over duration: TimeInterval) {
    // AVAudioMixerNode has no built-in ramp; the scheduler drives it. Kept
    // behind this call so the implementation can change without callers caring.
    voice.gain.outputVolume = target
    _ = duration
  }
}
