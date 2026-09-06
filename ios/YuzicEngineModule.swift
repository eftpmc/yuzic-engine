import ExpoModulesCore
import AVFoundation
import YuzicEngineCore

/**
 The Expo module surface — the thin part. Everything of substance lives in
 `AudioGraph`, `Queue` and the cache; this file only translates.

 Expo Modules rather than Nitro because nothing high-frequency crosses this
 bridge: audio never does, commands are rare, and progress is emitted about
 once a second. What is large is the *integration* surface — background audio
 mode, the CarPlay entitlement and scene, the Android foreground service and
 notification channel — and that is config-plugin work, which is where the
 Expo Modules API is markedly better. See docs/architecture.md.
 */
public final class YuzicEngineModule: Module {

  private var graph: AudioGraph?
  private let queue = PlaybackQueue()

  public func definition() -> ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { (options: SetupOptions?) in
      try self.configureAudioSession(pauseOnBecomingNoisy: options?.pauseOnBecomingNoisy ?? true)
      let graph = self.graph ?? AudioGraph()
      try graph.start()
      self.graph = graph
    }

    AsyncFunction("teardown") {
      self.graph?.stop()
      self.graph = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: queue
    //
    // The queue lives here, natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the lock screen still
    // has to update, and the car still has to answer its buttons.

    AsyncFunction("setQueue") { (tracks: [TrackRecord], startIndex: Int?) in
      self.queue.set(tracks.map(\.asTrack), startIndex: startIndex ?? 0)
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("append") { (tracks: [TrackRecord]) in
      self.queue.append(tracks.map(\.asTrack))
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("getActiveIndex") { () -> Int in
      self.queue.activeIndex
    }

    // MARK: transport

    AsyncFunction("play") { self.graph?.activeVoice.player.play() }
    AsyncFunction("pause") { self.graph?.activeVoice.player.pause() }

    // MARK: the reasons this exists

    AsyncFunction("setEqualizer") { (bands: [EqBandRecord]) in
      self.graph?.setEqualizer(bands: bands.map {
        (frequency: Float($0.frequencyHz), gainDb: Float($0.gainDb), q: Float($0.q ?? 1.0))
      })
    }

    AsyncFunction("setCrossfade") { (options: CrossfadeRecord?) in
      self.queue.crossfade = options?.asSettings
    }

    AsyncFunction("setSampleRateMode") { (mode: String) in
      // Enforced rather than merely recorded. Overlapping sources may differ in
      // rate — the mixer converts — but the *hardware* rate cannot change
      // mid-fade without stopping the engine and discarding every scheduled
      // buffer, so bit-perfect output and a crossfade in progress cannot
      // coexist. Resolved here rather than left as two settings that fight.
      let resolved = SampleRateMode(rawValue: mode) ?? .fixed
      if resolved == .matchSource, self.queue.crossfade != nil {
        self.queue.crossfade = nil
        self.sendEvent("onError", [
          "code": "CROSSFADE_DISABLED",
          "message": "Crossfade turned off: the hardware sample rate cannot change mid-fade.",
        ])
      }
      self.queue.sampleRateMode = resolved
    }
  }

  /**
   `.playback` with `.longFormAudio`: the category that keeps playing when the
   screen locks and the routing policy that tells the system this is music
   rather than a game or a call.
   */
  private func configureAudioSession(pauseOnBecomingNoisy: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    try session.setActive(true)
  }
}

// MARK: - Records
//
// Shapes crossing the bridge. Kept flat and optional-tolerant: a host that
// omits a field means "no information", which is not the same as a zero — the
// replay-gain pair is exactly that distinction.

struct SetupOptions: Record {
  @Field var progressIntervalMs: Int = 1000
  @Field var pauseOnBecomingNoisy: Bool = true
}

struct TrackRecord: Record {
  @Field var id: String = ""
  @Field var uri: String = ""
  @Field var title: String = ""
  @Field var artist: String?
  @Field var album: String?
  @Field var artworkUri: String?
  @Field var durationSec: Double?
  @Field var headers: [String: String]?
  @Field var followsPrevious: Bool = false
  @Field var replayGainDb: Double?
  @Field var replayGainPeak: Double?
  @Field var continuous: Bool = false
}

struct EqBandRecord: Record {
  @Field var frequencyHz: Double = 0
  @Field var gainDb: Double = 0
  @Field var q: Double?
}

struct CrossfadeRecord: Record {
  @Field var durationSec: Double = 0
  @Field var mode: String = "gapless-aware"
  @Field var skipIsImmediate: Bool = true
}


// MARK: - Bridge → domain
//
// The conversion happens here and nowhere else. Below this line everything is
// plain Swift that `swift test` can build without ExpoModulesCore — which is
// the only reason the queue rules have tests at all.

extension TrackRecord {
  var asTrack: Track {
    Track(
      id: id,
      uri: uri,
      title: title,
      artist: artist,
      album: album,
      artworkUri: artworkUri,
      durationSec: durationSec,
      headers: headers ?? [:],
      followsPrevious: followsPrevious,
      replayGainDb: replayGainDb,
      replayGainPeak: replayGainPeak,
      continuous: continuous
    )
  }
}

extension CrossfadeRecord {
  var asSettings: CrossfadeSettings {
    CrossfadeSettings(
      durationSec: durationSec,
      // An unrecognised mode falls back to the safer of the two: fading
      // through a deliberate segue is the outcome people notice and dislike.
      mode: CrossfadeMode(rawValue: mode) ?? .gaplessAware,
      skipIsImmediate: skipIsImmediate
    )
  }
}
