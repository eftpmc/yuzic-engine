import ExpoModulesCore
import AVFoundation

// No `import YuzicEngineCore` here, and that is not an oversight. The podspec
// compiles `ios/Core` and this file into a single module, so the core types are
// already in scope; SwiftPM is the odd one out, splitting Core into its own
// target so `swift test` can build the logic without an app. Importing it would
// be correct for the package and wrong for every real build.

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
  private var engine: PlaybackEngine?
  private var sleepTimer: SleepTimer?

  public func definition() -> ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { (options: SetupOptions?) in
      try self.configureAudioSession(pauseOnBecomingNoisy: options?.pauseOnBecomingNoisy ?? true)

      if self.engine == nil {
        let graph = AudioGraph()
        try graph.start()
        let engine = PlaybackEngine(graph: graph, factory: HTTPTrackReaderFactory())
        engine.onEvent = { [weak self] event in self?.forward(event) }
        self.graph = graph
        self.engine = engine
        self.sleepTimer = SleepTimer { [weak self] fade in
          // Fade rather than cut: music stopping mid-bar is what wakes people,
          // which is the opposite of the point.
          guard let self, let graph = self.graph else { return }
          graph.fade(graph.activeVoice, to: 0, over: fade) { self.engine?.pause() }
        }
      }
    }

    AsyncFunction("teardown") {
      self.engine?.stop()
      self.engine = nil
      self.graph?.stop()
      self.graph = nil
      self.sleepTimer?.cancel()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: queue
    //
    // The queue lives here, natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the lock screen still
    // has to update, and the car still has to answer its buttons.

    AsyncFunction("setQueue") { (tracks: [TrackRecord], startIndex: Int?) in
      self.engine?.setQueue(tracks.map(\.asTrack), startIndex: startIndex ?? 0)
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("append") { (tracks: [TrackRecord]) in
      self.engine?.queue.append(tracks.map(\.asTrack))
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("getActiveIndex") { () -> Int in
      self.engine?.queue.activeIndex ?? 0
    }

    // MARK: transport

    AsyncFunction("play") { try self.engine?.play() }
    AsyncFunction("pause") { self.engine?.pause() }
    AsyncFunction("stop") { self.engine?.stop() }
    AsyncFunction("seekTo") { (positionSec: Double) in try self.engine?.seek(toSeconds: positionSec) }
    AsyncFunction("skipToNext") { try self.engine?.skipToNext() }
    AsyncFunction("skipToPrevious") { try self.engine?.skipToPrevious() }
    AsyncFunction("skipToIndex") { (index: Int) in try self.engine?.skipTo(index: index) }
    AsyncFunction("setVolume") { (volume: Double) in
      self.graph.map { $0.activeVoice.gain.outputVolume = Float(max(0, min(1, volume))) }
    }

    // MARK: sleep timer

    AsyncFunction("sleepAfter") { (seconds: Double) in self.sleepTimer?.schedule(after: seconds) }
    AsyncFunction("cancelSleep") { self.sleepTimer?.cancel() }

    // MARK: the reasons this exists

    AsyncFunction("setEqualizer") { (bands: [EqBandRecord]) in
      self.graph?.setEqualizer(bands: bands.map {
        (frequency: Float($0.frequencyHz), gainDb: Float($0.gainDb), q: Float($0.q ?? 1.0))
      })
    }

    AsyncFunction("setCrossfade") { (options: CrossfadeRecord?) in
      self.engine?.queue.crossfade = options?.asSettings
    }

    AsyncFunction("setSampleRateMode") { (mode: String) in
      // Enforced rather than merely recorded. Overlapping sources may differ in
      // rate — the mixer converts — but the *hardware* rate cannot change
      // mid-fade without stopping the engine and discarding every scheduled
      // buffer, so bit-perfect output and a crossfade in progress cannot
      // coexist. Resolved here rather than left as two settings that fight.
      let resolved = SampleRateMode(rawValue: mode) ?? .fixed
      if resolved == .matchSource, self.engine?.queue.crossfade != nil {
        self.engine?.queue.crossfade = nil
        self.sendEvent("onError", [
          "code": "CROSSFADE_DISABLED",
          "message": "Crossfade turned off: the hardware sample rate cannot change mid-fade.",
        ])
      }
      self.engine?.queue.sampleRateMode = resolved
    }
  }

  /**
   `.playback` with `.longFormAudio`: the category that keeps playing when the
   screen locks and the routing policy that tells the system this is music
   rather than a game or a call.
   */
  /// Engine events, translated for JavaScript. One place, so the event names
  /// and payload shapes cannot drift between here and the TypeScript types.
  private func forward(_ event: PlaybackEngine.Event) {
    switch event {
    case .stateChanged(let state):
      sendEvent("onStateChange", ["state": state.rawValue])
    case .trackChanged(let index, let id, let listened):
      var payload: [String: Any] = ["index": index]
      if let id { payload["id"] = id }
      if let listened { payload["previousListenedSec"] = listened }
      sendEvent("onTrackChange", payload)
    case .progress(let position, let duration):
      sendEvent("onProgress", ["positionSec": position, "durationSec": duration])
    case .ended:
      sendEvent("onStateChange", ["state": "ended"])
    case .failed(let message):
      sendEvent("onError", ["code": "PLAYBACK_FAILED", "message": message])
    }
  }

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
