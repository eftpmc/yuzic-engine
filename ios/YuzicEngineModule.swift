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

    // Queue editing. Declared in `src/AudioEngine.ts` since the beginning and
    // implemented by nothing until now, which is what was standing between the
    // host and deleting its current player — yuzic edits its queue through
    // every one of these.
    //
    // None of them touch playback. Editing a list and changing what is playing
    // are different actions, and the queue's own index adjustments exist to
    // keep the second from happening as a side effect of the first.

    AsyncFunction("insertAt") { (index: Int, tracks: [TrackRecord]) in
      self.engine?.queue.insert(tracks.map(\.asTrack), at: index)
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("removeAt") { (index: Int) in
      self.engine?.queue.remove(at: index)
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("move") { (fromIndex: Int, toIndex: Int) in
      self.engine?.queue.move(from: fromIndex, to: toIndex)
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("clearQueue") {
      self.engine?.queue.clear()
      self.sendEvent("onQueueChange", [:])
    }

    AsyncFunction("getQueue") { () -> [[String: Any]] in
      (self.engine?.queue.tracks ?? []).map(\.asRecordDictionary)
    }

    AsyncFunction("setRepeatMode") { (mode: String) in
      self.engine?.queue.repeatMode = RepeatMode(rawValue: mode) ?? .off
    }

    // MARK: transport

    AsyncFunction("getState") { () -> String in
      self.engine?.state.rawValue ?? PlaybackEngine.PlaybackState.idle.rawValue
    }

    /**
     Asked rather than waited for.

     Progress arrives as an event on a timer, which is no use to a screen that
     has just mounted mid-track — it would show zero until the next tick.
     */
    AsyncFunction("getProgress") { () -> [String: Any] in
      let progress = self.engine?.progress ?? (positionSec: 0, durationSec: 0, bufferedSec: 0)
      return [
        "positionSec": progress.positionSec,
        "durationSec": progress.durationSec,
        "bufferedSec": progress.bufferedSec,
      ]
    }

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

    /**
     Loudness normalisation, from the host's tags.

     The engine never measures loudness itself: measuring means decoding a
     whole track before it can play, which is the thing this player exists not
     to do. The figures are already in the files.
     */
    AsyncFunction("setReplayGain") { (options: ReplayGainRecord) in
      self.engine?.replayGain = options.asSettings
    }

    AsyncFunction("setCrossfade") { (options: CrossfadeRecord?) in
      self.engine?.queue.crossfade = options?.asSettings
    }

    /**
     Hand the car its browse tree.

     Pushed down in advance rather than served on demand, because the car asks
     when the app's JavaScript is asleep — someone starts driving, the phone
     connects, and there is no runtime awake to answer. A tree that has to be
     fetched from JS is a tree that is sometimes empty at exactly the wrong
     moment.
     */
    AsyncFunction("setBrowseTree") { (title: String, nodes: [BrowseNodeRecord]) in
      let tree = BrowseTree.build(title: title, from: nodes.map(\.asFlatNode))
      CarPlayCoordinator.shared.setRoot(tree)
      CarPlayCoordinator.shared.setPlayHandler { [weak self] tracks, index in
        guard let self else { return }
        // Played natively rather than round-tripped through JS, for the same
        // reason the tree is: nothing may be listening. The host finds out
        // afterwards through the ordinary track-change event.
        self.engine?.setQueue(tracks, startIndex: index)
        try? self.engine?.play()
        self.sendEvent("onQueueChange", [:])
      }
    }

    /**
     Which remote controls to advertise.

     Not a fixed property of the engine: a podcast wants skip-forward rather
     than next-track, and a live stream should not draw a scrubber over
     something with no end.
     */
    AsyncFunction("setCommands") { (commands: [String]) in
      // An unrecognised name is dropped rather than defaulted. Advertising a
      // control the host never asked for is how a car ends up with a button
      // that does nothing.
      self.engine?.remoteCommands = commands.compactMap { RemoteCommand(rawValue: $0) }
    }

    AsyncFunction("clearBrowseTree") {
      CarPlayCoordinator.shared.setRoot(nil)
      CarPlayCoordinator.shared.setPlayHandler(nil)
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
    case .progress(let position, let duration, let buffered):
      sendEvent("onProgress", [
        "positionSec": position, "durationSec": duration, "bufferedSec": buffered,
      ])
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

/**
 One browse node, flat.

 Flat because a `Record` cannot contain itself — `@Field` has no way to
 describe recursion — so the tree crosses the bridge as a list with parent
 references and is rebuilt on this side.
 */
struct BrowseNodeRecord: Record {
  @Field var id: String = ""
  @Field var parentId: String?
  @Field var title: String = ""
  @Field var subtitle: String?
  @Field var artworkUri: String?
  @Field var playable: TrackRecord?
}

struct EqBandRecord: Record {
  @Field var frequencyHz: Double = 0
  @Field var gainDb: Double = 0
  @Field var q: Double?
}

struct ReplayGainRecord: Record {
  @Field var mode: String = "off"
  @Field var preampDb: Double = 0
  @Field var untaggedPreampDb: Double = 0
  @Field var preventClipping: Bool = true
}

struct CrossfadeRecord: Record {
  @Field var durationSec: Double = 0
  @Field var mode: String = "gapless-aware"
  @Field var skipIsImmediate: Bool = true
}


// MARK: - Domain → bridge
//
// Only `getQueue` needs this direction: everything else the host learns comes
// through an event, and events carry figures rather than tracks. Hand-built
// rather than made `Codable`, so that the keys here and the `Track` fields in
// src/types.ts are visibly the same list and drift is a visible diff.

extension Track {
  var asRecordDictionary: [String: Any] {
    var out: [String: Any] = [
      "id": id,
      "uri": uri,
      "title": title,
      "followsPrevious": followsPrevious,
      "continuous": continuous,
    ]
    // Absent rather than null: `durationSec` missing means the host never knew,
    // and a JSON null would arrive as 0 and be believed.
    if let artist { out["artist"] = artist }
    if let album { out["album"] = album }
    if let artworkUri { out["artworkUri"] = artworkUri }
    if let durationSec { out["durationSec"] = durationSec }
    if !headers.isEmpty { out["headers"] = headers }
    if let replayGainDb { out["replayGainDb"] = replayGainDb }
    if let replayGainPeak { out["replayGainPeak"] = replayGainPeak }
    return out
  }
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

extension BrowseNodeRecord {
  var asFlatNode: BrowseTree.FlatNode {
    BrowseTree.FlatNode(
      id: id,
      parentId: parentId,
      title: title,
      subtitle: subtitle,
      artworkUri: artworkUri,
      playable: playable?.asTrack
    )
  }
}

extension ReplayGainRecord {
  var asSettings: ReplayGainSettings {
    ReplayGainSettings(
      // An unrecognised mode means off rather than a guess: silently applying
      // an adjustment nobody asked for is worse than applying none.
      mode: ReplayGainMode(rawValue: mode) ?? .off,
      preampDb: preampDb,
      untaggedPreampDb: untaggedPreampDb,
      preventClipping: preventClipping
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
