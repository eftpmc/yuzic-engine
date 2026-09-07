import Foundation
import AVFoundation

/// Opens a decodable stream for a track. Injected so the engine can be driven
/// from fixtures in a test without a network, and so the choice between the two
/// transports lives in one place rather than inside the engine.
public protocol TrackReaderFactory {
  func makeReader(for track: Track) throws -> TrackReader
}

/**
 The player: queue, graph, and the rules about moving between tracks.

 Two `TrackPlayback`s, one per voice, alternating. While one is playing the
 other is either idle or being prepared, and a crossfade is the window where
 both are running and their gains are moving in opposite directions.

 Everything about *when* to move is decided here rather than in JavaScript,
 because a backgrounded app's JS is suspended and the transition still has to
 happen. `PlaybackQueue.transitionDuration` supplies the how-long; this supplies
 the when.
 */
public final class PlaybackEngine {

  public enum Event {
    case stateChanged(PlaybackState)
    /// Fired at the crossover point, so it lines up with what is being heard
    /// rather than with when the machinery started moving. `listenedSec` is the
    /// outgoing track's played time *including* its fade-out — a host
    /// scrobbling on "half the track" needs that, or a long crossfade silently
    /// stops it ever reaching the threshold.
    case trackChanged(index: Int, id: MediaId?, previousListenedSec: Double?)
    case progress(positionSec: Double, durationSec: Double, bufferedSec: Double)
    case ended
    case failed(String)
  }

  public enum PlaybackState: String {
    case idle, buffering, playing, paused, ended
  }

  private let graph: AudioGraph
  private let factory: TrackReaderFactory
  private let nowPlaying: NowPlayingCenter
  public let queue = PlaybackQueue()

  private var activePlayback: TrackPlayback?
  private var incomingPlayback: TrackPlayback?
  /// What the idle voice is carrying during a crossfade, so volume can reach it.
  private var incomingTrack: Track?
  private var activeReader: TrackReader?

  private var ticker: Timer?
  private var transitioning = false

  /**
   How long the current track has actually been playing.

   Two values rather than one start date, because a start date measures wall
   clock and a paused player is not listening. A track left paused overnight
   would report the whole night as listened, and `previousListenedSec` is what
   scrobble thresholds are judged against — so the wrong number here submits
   plays to Last.fm and ListenBrainz for music nobody heard.

   `listenedAccumulated` holds the stretches already played;
   `listeningSince` marks the open one and is nil while paused.
   */
  private var listenedAccumulated: TimeInterval = 0
  private var listeningSince: Date?

  /**
   The fix point the lock screen is extrapolating from.

   `elapsedPlaybackTime` is a fix point, not a clock: iOS advances it itself
   using the rate, which is why it is not re-sent on every tick — doing that
   four times a second makes the lock-screen timer visibly stutter as it is
   yanked back to a value already going stale.

   But the engine's position comes from *rendered* frames, and those stop
   advancing during a buffering stall while the wall clock does not. So the
   two drift apart, always in the same direction: the lock screen runs ahead
   of the audio. Pausing publishes the truth and the number jumps backwards —
   which is what a listener sees, as a paused screen showing an earlier time
   than the playing one did a moment before.
   */
  private var publishedPosition: Double?
  private var publishedAt: Date?

  private var observers: [NSObjectProtocol] = []

  /// Set while an interruption is in force, so `.ended` only resumes playback
  /// that *this* engine paused — not playback the user had already stopped.
  private var pausedByInterruption = false

  /// Injectable so the listened-time tests do not have to sleep.
  private let now: () -> Date

  private(set) public var state: PlaybackState = .idle {
    didSet { if state != oldValue { emit(.stateChanged(state)) } }
  }

  public var onEvent: ((Event) -> Void)?

  /**
   Loudness normalisation. Off until the host says otherwise.

   Changing it takes effect on the track already playing as well as the next
   one. The alternative — settling in only at the next track boundary — makes
   the setting feel broken: someone turns it on precisely because what they are
   hearing right now is too loud.
   */
  public var replayGain: ReplayGainSettings = .off {
    didSet {
      guard replayGain != oldValue else { return }
      applyVolume()
    }
  }

  /**
   The user's volume, held here rather than written onto a gain node.

   It has to live somewhere: `AudioGraph.setTrackGain` explains that a fade
   ramps `gain.outputVolume` from 0 to 1 and anything else written there is
   overwritten by the next ramp. Volume was being written exactly there, so it
   survived only until the next fade, skip or track change — and a skip taken
   during a crossfade left the voice stranded at whatever the abandoned ramp
   had reached, with the next volume command writing to a node nothing would
   read again until the following track.

   Multiplied into the player alongside replay gain instead, which is the
   separation that lets the two coexist.
   */
  public var volume: Float = 1 {
    didSet {
      volume = min(max(volume, 0), 1)
      applyVolume()
    }
  }

  /// `volume × replay gain` for a track, which is what the player wants.
  private func playerGain(for track: Track?) -> Float {
    guard let track else { return volume }
    return volume * ReplayGain.linearGain(for: track, settings: replayGain)
  }

  /**
   Push volume to both voices, each for its own track.

   Both, because during a crossfade two of them are audible and leaving one
   behind makes the change lurch halfway through the fade — the same reason
   Android applies it to both.
   */
  private func applyVolume() {
    graph.setTrackGain(graph.activeVoice, to: playerGain(for: queue.activeTrack))
    if transitioning {
      graph.setTrackGain(graph.idleVoice, to: playerGain(for: incomingTrack))
    }
  }

  public init(
    graph: AudioGraph,
    factory: TrackReaderFactory,
    nowPlaying: NowPlayingCenter = NowPlayingCenter(),
    now: @escaping () -> Date = Date.init
  ) {
    self.graph = graph
    self.factory = factory
    self.nowPlaying = nowPlaying
    self.now = now
    wireRemoteCommands()
    observeTheSystem()
  }

  /// The lock screen, Control Centre, headphone buttons and the car all arrive
  /// here. They are wired once at construction rather than per track: a control
  /// that disappears between tracks is worse than one that was never offered.
  /**
   Which controls to advertise.

   Worth being able to change, because the right set is not a property of the
   engine. A podcast wants skip-forward rather than next-track; a live stream
   should not offer a scrubber over a thing with no end. Defaults to the four
   that suit music.

   A control that is offered but does nothing is worse than one that is absent,
   so this is a list of what the host will honour, not everything the framework
   can draw.
   */
  public var remoteCommands: [RemoteCommand] = [.playPause, .next, .previous, .seek] {
    // Re-wired on every set, not only when the list changes. The guard that
    // used to be here read as free — re-registering the same commands is a
    // no-op — but it assumed this engine is the only thing touching
    // `MPRemoteCommandCenter.shared()`, and during the migration off
    // @rntp/player it is not: that library's `destroy()` calls
    // `removeTarget(nil)` on every command, which removes *everyone's*
    // targets. Setting the same list again is then the host's only way to say
    // "put mine back", and the guard turned that into nothing. The symptom is
    // controls greyed out on the lock screen while the now-playing info still
    // updates, because the info centre is a different singleton and survives.
    didSet { wireRemoteCommands() }
  }

  private func wireRemoteCommands() {
    var handlers = RemoteCommandHandlers()
    handlers.play = { [weak self] in try? self?.play() }
    handlers.pause = { [weak self] in self?.pause() }
    handlers.next = { [weak self] in try? self?.skipToNext() }
    handlers.previous = { [weak self] in try? self?.skipToPrevious() }
    handlers.seek = { [weak self] position in try? self?.seek(toSeconds: position) }
    handlers.stop = { [weak self] in self?.stop() }
    nowPlaying.setCommands(remoteCommands, handlers: handlers)
  }

  /**
   Push the current track and state to the lock screen.

   Called on every transition and on pause/resume, *not* on every progress tick.
   `elapsedPlaybackTime` is a fix point that iOS extrapolates from using the
   rate — re-sending it four times a second makes the lock-screen timer stutter
   as it is repeatedly yanked back to a value already going stale.
   */
  private func publishNowPlaying() {
    guard let track = queue.activeTrack, let reader = activeReader else {
      nowPlaying.clear()
      publishedPosition = nil
      return
    }
    let sampleRate = reader.sampleRate > 0 ? reader.sampleRate : 44_100
    let position = Double(activePlayback?.currentFrame ?? 0) / sampleRate
    publishedPosition = position
    publishedAt = now()
    nowPlaying.update(
      .init(
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationSec: track.continuous ? 0 : Double(reader.totalFrames) / sampleRate,
        positionSec: position,
        isPlaying: state == .playing,
        rate: 1.0,
        isLive: track.continuous
      ),
      artworkUri: track.artworkUri
    )
  }

  deinit {
    ticker?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  // MARK: - The system taking the audio away

  /**
   Three things the system does to a running audio graph, none of which it
   asks permission for.

   None of these were observed. `handleConfigurationChange` existed, documented
   exactly this, and had no callers — so when another app took the route, iOS
   stopped the engine underneath us and this one carried on scheduling into a
   dead graph. Somebody's partner starting Spotify in the car is enough.
   */
  private func observeTheSystem() {
    let centre = NotificationCenter.default

    // The engine is stopped and every scheduled buffer is discarded. Fires on
    // any route change — CarPlay connecting, AirPods, a dock — and there is no
    // way to recover the buffers, so playback has to be rebuilt from where it
    // had reached.
    observers.append(centre.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
    ) { [weak self] _ in
      self?.rebuildAfterConfigurationChange()
    })

    // `AVAudioSession` is iOS-only, and this package also builds for macOS so
    // the logic can be tested without a device. The configuration-change
    // notification above exists on both.
    #if os(iOS) || os(tvOS)
    // Another app has taken the session — a call, or Spotify on the same
    // Bluetooth device.
    observers.append(centre.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      self?.handleInterruption(note)
    })

    // The output vanished. Unplugging headphones must pause rather than
    // continue out of the speaker, which is the one route change with an
    // obvious right answer.
    observers.append(centre.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self,
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
      else { return }
      self.pause()
    })
    #endif
  }

  /**
   Whether an interruption ending should resume playback.

   Pure, because the rule is the part worth pinning: resume only what this
   engine paused, and only when the system says the interrupting app has
   finished with the session. Resuming otherwise starts music in someone's ear
   after a phone call they took while the player was already stopped.
   */
  static func shouldResumeAfterInterruption(
    wasPausedByUs: Bool, systemSaysResume: Bool
  ) -> Bool {
    wasPausedByUs && systemSaysResume
  }

  #if os(iOS) || os(tvOS)
  private func handleInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

    switch type {
    case .began:
      pausedByInterruption = state == .playing || state == .buffering
      pause()
    case .ended:
      let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      let resume = Self.shouldResumeAfterInterruption(
        wasPausedByUs: pausedByInterruption,
        systemSaysResume: options.contains(.shouldResume)
      )
      pausedByInterruption = false
      if resume {
        // The session was deactivated under us; it has to be reclaimed before
        // the graph will run again.
        try? AVAudioSession.sharedInstance().setActive(true)
        try? play()
      }
    @unknown default:
      break
    }
  }

  #endif

  /**
   Put playback back together after the system tore the graph down.

   The position is read *before* anything is rebuilt, because restarting the
   engine is what makes it unreadable. Everything else is the ordinary start
   path: a fresh `TrackPlayback` over the same reader, seeking to where the
   listener actually was.
   */
  private func rebuildAfterConfigurationChange() {
    guard let playback = activePlayback, let reader = activeReader, reader.sampleRate > 0 else {
      return
    }
    let frame = playback.currentFrame
    let resume = state == .playing || state == .buffering

    playback.stopAndWait()

    do {
      try graph.handleConfigurationChange()
      graph.reconnect(graph.activeVoice, toSourceRate: reader.sampleRate)

      let fresh = TrackPlayback(reader: reader, voice: graph.activeVoice)
      fresh.onEndOfTrack = { [weak self, weak fresh] in self?.handleTrackFinished(fresh) }
      fresh.onFirstBufferScheduled = { [weak self, weak fresh] in
        DispatchQueue.main.async {
          guard let self, self.activePlayback === fresh, self.state == .buffering else { return }
          self.state = .playing
          self.publishNowPlaying()
        }
      }
      activePlayback = fresh
      graph.cut(graph.activeVoice, to: 1)

      if resume {
        state = .buffering
        try fresh.start(atFrame: frame)
      } else {
        // Rebuilt but left where it was: a route change while paused should
        // not start the music.
        try fresh.start(atFrame: frame)
        fresh.pause()
      }
      publishNowPlaying()
    } catch {
      emit(.failed("audio graph could not be rebuilt after a route change: \(error)"))
    }
  }

  // MARK: - Transport

  public func setQueue(_ tracks: [Track], startIndex: Int) {
    stopEverything()
    queue.set(tracks, startIndex: startIndex)
    state = .idle
  }

  public func play() throws {
    if activePlayback == nil {
      try beginTrack(at: queue.activeIndex, fromFrame: 0)
    } else {
      // Restore the voice, because something may have faded it away while it
      // was paused. The sleep timer does exactly that: it fades to silence and
      // pauses, leaving the gain at zero. Without this, play the next morning
      // resumes a track nobody can hear, with the progress bar advancing
      // normally — which reads as a broken player rather than a sleep timer
      // that did its job.
      //
      // Skipped mid-transition, where both voices are deliberately part-way
      // through a ramp and slamming one to full would be audible.
      if !transitioning {
        graph.cut(graph.activeVoice, to: 1)
      }
      activePlayback?.resume()
      // Reopen the listening stretch the pause closed. Guarded so that calling
      // play() on an already-playing engine does not discard the open stretch
      // and restart it, which would quietly reset the count to zero.
      if listeningSince == nil { listeningSince = now() }
      state = .playing
      publishNowPlaying()
      startTicking()
    }
  }

  public func pause() {
    activePlayback?.pause()
    incomingPlayback?.pause()
    closeListeningStretch()
    state = .paused
    publishNowPlaying()
    stopTicking()
  }

  /// Bank the stretch that has just ended. Idempotent, because pausing an
  /// already-paused player must not bank the same seconds twice.
  private func closeListeningStretch() {
    guard let since = listeningSince else { return }
    listenedAccumulated += now().timeIntervalSince(since)
    listeningSince = nil
  }

  public func stop() {
    stopEverything()
    state = .idle
  }

  public func seek(toSeconds seconds: Double) throws {
    guard let reader = activeReader else { return }
    // A seek during a fade would leave the other voice playing the wrong part
    // of the wrong track; collapse the transition first.
    cancelTransition()
    let frame = Int64(seconds * reader.sampleRate)
    // Waits, unlike everywhere else `stop` is called: the reader below is the
    // one this playback is decoding from, and it cannot be seeked while the
    // old producer is still inside it.
    activePlayback?.stopAndWait()
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    playback.onEndOfTrack = { [weak self, weak playback] in self?.handleTrackFinished(playback) }
    activePlayback = playback
    try playback.start(atFrame: frame)
    state = .playing
    // A seek moves the fix point, so the lock screen has to be told or its
    // timer carries on from where the track used to be.
    publishNowPlaying()
    startTicking()
  }

  public func skipToNext() throws {
    // Through the queue, so that repeat is honoured here the same way the
    // automatic advance honours it. Computing `activeIndex + 1` here meant a
    // repeat-all queue wrapped when a track ended and stopped when the user
    // pressed next.
    try move(to: queue.skipNextIndex, userInitiated: true)
  }

  public func skipToPrevious() throws {
    switch PlaybackEngine.previousAction(
      positionSec: progress.positionSec, activeIndex: queue.activeIndex
    ) {
    case .restart: try seek(toSeconds: 0)
    case .goBack: try move(to: queue.activeIndex - 1, userInitiated: true)
    }
  }

  /// What `previous` means, which is not always "the previous track".
  public enum PreviousAction: Equatable { case restart, goBack }

  /// How far into a track `previous` stops meaning "go back" and starts
  /// meaning "start this one again".
  public static let previousRestartsAfterSec: Double = 3

  /**
   Whether `previous` restarts the current track or moves to the one before.

   Past three seconds a person pressing previous almost always means "start
   this again" rather than "leave" — and on the first track there is nothing to
   leave to, so restarting is the only thing it can usefully do. iOS had
   neither rule: it moved unconditionally, which on the first track computed
   -1, was rejected by `move`, and did nothing at all.

   Pure and separate for the same reason `shouldBeginTransition` is: it is the
   decision, and driving three seconds of real audio to test it would test the
   plumbing instead. Android's threshold is the same constant.
   */
  public static func previousAction(positionSec: Double, activeIndex: Int) -> PreviousAction {
    if positionSec > previousRestartsAfterSec || activeIndex == 0 { return .restart }
    return .goBack
  }

  public func skipTo(index: Int) throws {
    try move(to: index, userInitiated: true)
  }

  // MARK: - Moving between tracks

  private func move(to index: Int, userInitiated: Bool) throws {
    guard queue.tracks.indices.contains(index) else {
      if index >= queue.tracks.count { finish() }
      return
    }
    let listened = listenedSeconds()
    cancelTransition()

    // Opened *before* the outgoing track is touched. `open()` on a remote
    // track is a network round trip, and silencing and stopping the outgoing
    // track first meant the gap between pressing skip and hearing anything was
    // however long that fetch took — reported from a car as several seconds of
    // nothing, and absent on a downloaded playlist, where opening a local file
    // is instant. Audio renders on its own thread, so the outgoing track keeps
    // playing throughout this.
    //
    // It also means a failure to open leaves the current track playing rather
    // than stopping it and cutting its gain to zero, which is a better answer
    // to a skip that cannot be served than silence.
    let reader = try factory.makeReader(for: queue.tracks[index])
    try reader.open()

    // A skip is a cut, not a fade — `transitionDuration` says so, and here it
    // is honoured by not starting one at all.
    graph.cut(graph.activeVoice, to: 0)
    activePlayback?.stop()

    queue.set(queue.tracks, startIndex: index)
    try beginTrack(at: index, fromFrame: 0, previousListenedSec: listened, prepared: reader)
  }

  private func beginTrack(at index: Int, fromFrame frame: Int64,
                          previousListenedSec: Double? = nil,
                          prepared: TrackReader? = nil) throws {
    guard let track = queue.tracks.indices.contains(index) ? queue.tracks[index] : nil else {
      finish()
      return
    }

    state = .buffering
    // `prepared` is a reader the caller already opened, which is how a skip
    // avoids a silent gap — see `move`. Opening here is the path for callers
    // that have nothing playing to protect.
    let reader: TrackReader
    if let prepared {
      reader = prepared
    } else {
      reader = try factory.makeReader(for: track)
      try reader.open()
    }

    // This path starts the track on the *active* voice, so that is the one that
    // has to match the file's rate — reconnecting the idle voice here would
    // prepare the one node that is not about to be used, and leave the playing
    // one on whatever rate it last had (48kHz on a fresh graph). The track then
    // plays 8.8% fast and a semitone and a half sharp, because the node reads
    // the reader's 44.1kHz buffers as 48kHz ones; the position is wrong by the
    // same ratio. Safe to reconnect because this voice is not playing yet; the
    // crossfade path is the one that must use the idle voice.
    graph.reconnect(graph.activeVoice, toSourceRate: reader.sampleRate)

    activeReader = reader
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    playback.onEndOfTrack = { [weak self, weak playback] in self?.handleTrackFinished(playback) }
    activePlayback = playback

    graph.setTrackGain(graph.activeVoice, to: playerGain(for: track))
    graph.cut(graph.activeVoice, to: 1)

    // `.playing` is announced when audio actually starts, not here. `start()`
    // only dispatches the decode, and that decode blocks on the network — so
    // on a slow connection this used to report playing while nothing had been
    // scheduled, and the player sat at 0:00 behind a pause button with no way
    // to say it was still waiting. Staying in `.buffering` until the first
    // buffer is handed to the node makes the state mean what it says.
    playback.onFirstBufferScheduled = { [weak self, weak playback] in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === playback, self.state == .buffering else { return }
        self.state = .playing
        self.publishNowPlaying()
      }
    }

    try playback.start(atFrame: frame)
    listenedAccumulated = 0
    listeningSince = now()

    emit(.trackChanged(index: index, id: track.id, previousListenedSec: previousListenedSec))
    publishNowPlaying()
    startTicking()
  }

  /// Called when a track runs out with no crossfade to carry it.
  /**
   A track reached its end. Advance, unless it was not the track being heard.

   `finished` is the playback that ended, and it is checked against the active
   one rather than trusted. During a crossfade the *outgoing* track keeps
   playing to its own natural end, several seconds after the crossover has
   already moved the queue on — so without this it advances a second time and
   the listener is thrown into a third track.

   `transitioning` does not cover it: that is cleared at the crossover, which
   is the midpoint of the fade, leaving the whole second half of the window in
   which the outgoing track can still end with the guard already down. Identity
   holds whatever the timing.
   */
  private func handleTrackFinished(_ finished: TrackPlayback?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.transitioning else { return }
      guard finished == nil || finished === self.activePlayback else { return }
      let listened = self.listenedSeconds()
      // Asks the queue rather than adding one, so repeat is honoured in the
      // one place it has to be: `.one` returns the same index and the track
      // starts again, `.all` wraps at the end instead of finishing.
      guard let next = self.queue.nextIndex else { self.finish(); return }
      self.queue.set(self.queue.tracks, startIndex: next)
      try? self.beginTrack(at: next, fromFrame: 0, previousListenedSec: listened)
    }
  }

  // MARK: - The crossfade

  /**
   Whether the lock screen's fix point needs re-sending.

   True when what iOS is showing — the last published position plus the wall
   time since, since it extrapolates at the playback rate — has drifted from
   the real position by more than a second. A second is under the threshold
   where a listener would notice a correction, and well above the jitter of
   a tick that runs four times a second.

   Pure, so the threshold and the direction can be tested without a lock
   screen. Direction matters: drift is one-sided in practice, because
   rendered frames fall behind wall clock during a stall and never run ahead
   of it, but this is written symmetrically rather than assuming that.
   */
  static func shouldRepublish(
    actual: Double, published: Double?, publishedAt: Date?, now: Date,
    tolerance: Double = 1.0
  ) -> Bool {
    guard let published, let publishedAt else { return true }
    let expected = published + now.timeIntervalSince(publishedAt)
    return abs(actual - expected) > tolerance
  }

  /**
   Whether it is time to start fading into the next track.

   Pure, and separated out because it is the one piece of this worth testing
   directly: everything else here is plumbing around a timer.
   */
  public static func shouldBeginTransition(
    positionSec: Double, durationSec: Double, transitionSec: Double
  ) -> Bool {
    guard transitionSec > 0, durationSec > 0 else { return false }
    return positionSec >= durationSec - transitionSec
  }

  /**
   Which duration to believe when deciding where a track ends.

   The reader derives its length from bytes, and for a transcoding endpoint
   that length is an estimate the server was never obliged to get right — a
   Subsonic or Jellyfin transcode can declare a byte count that maps to far
   less audio than the song contains. Deciding the fade from it starts the
   crossfade in the middle of the track.

   The host's own metadata is the song's real length, so when the two disagree
   by more than a rounding error, that is the one to trust. When they agree,
   the reader's is preferred: it is the decoded truth, exact for a local file
   and already corrected for encoder padding.

   `nil` means the host does not know, which is not the same as zero.
   */
  public static func referenceDuration(readerSec: Double, declaredSec: Double?) -> Double {
    guard let declaredSec, declaredSec > 0 else { return readerSec }
    guard readerSec > 0 else { return declaredSec }
    let disagreement = abs(readerSec - declaredSec) / declaredSec
    return disagreement > 0.05 ? declaredSec : readerSec
  }

  /**
   Where playback is now, asked rather than waited for.

   The host gets this as an event on a timer, but an event stream is no use to
   something that has just mounted: a screen opened mid-track would show zero
   until the next tick. Cheap enough to ask directly, and it reads the same
   values the tick emits rather than a cached copy that could disagree.
   */
  public var progress: (positionSec: Double, durationSec: Double, bufferedSec: Double) {
    guard let playback = activePlayback, let reader = activeReader, reader.sampleRate > 0 else {
      return (0, 0, 0)
    }
    let frame = playback.currentFrame
    let position = Double(frame) / reader.sampleRate
    return (
      position,
      // A live stream has no finish line, and reporting the bytes fetched so
      // far as a duration draws a progress bar that lies. Neither does a
      // byte-derived length that disagrees with the host — see
      // `referenceDuration`. The seek bar and the crossfade have to be reading
      // the same clock, or the track ends somewhere the bar never reaches.
      queue.activeTrack?.continuous == true
        ? 0
        : Self.referenceDuration(
            readerSec: Double(reader.totalFrames) / reader.sampleRate,
            declaredSec: queue.activeTrack?.durationSec
          ),
      // Absolute, not relative: a buffering bar is drawn against the same
      // timeline as the position, so a figure measured from the playhead would
      // sit at the wrong end of it.
      position + Double(reader.bufferedFramesAhead(ofFrame: frame)) / reader.sampleRate
    )
  }

  private func tick() {
    guard let playback = activePlayback, let reader = activeReader, reader.sampleRate > 0 else { return }
    // Read once, through the same accessor `getProgress` uses, so the event
    // and the answer to a direct question cannot drift apart.
    let (position, duration, buffered) = progress
    emit(.progress(positionSec: position, durationSec: duration, bufferedSec: buffered))

    // Correct the lock screen when it has drifted, rather than on a timer.
    // Re-sending the fix point every tick stutters; leaving it alone lets the
    // error accumulate for the length of a track. Doing it only when the two
    // actually disagree costs one comparison and bounds the error at the
    // threshold.
    if state == .playing, Self.shouldRepublish(
      actual: position, published: publishedPosition,
      publishedAt: publishedAt, now: now()
    ) {
      publishNowPlaying()
    }

    guard !transitioning else { return }
    let fade = queue.transitionDuration(userInitiated: false)
    // `duration` is already the trusted one — `progress` applies
    // `referenceDuration` so the seek bar and the fade cannot disagree.
    guard Self.shouldBeginTransition(positionSec: position, durationSec: duration, transitionSec: fade) else {
      return
    }
    beginTransition(over: fade)
  }

  private func beginTransition(over duration: TimeInterval) {
    guard let next = queue.nextTrack else { return }
    transitioning = true

    do {
      let reader = try factory.makeReader(for: next)
      try reader.open()
      graph.reconnectIdleVoice(toSourceRate: reader.sampleRate)

      let incoming = TrackPlayback(reader: reader, voice: graph.idleVoice, label: "decode.incoming")
      incomingPlayback = incoming
      // Set before the fade begins, not at the crossover: a track arriving at
      // the wrong loudness and being corrected halfway through the fade is
      // audible in a way that the correction itself is supposed to prevent.
      incomingTrack = next
      graph.setTrackGain(graph.idleVoice, to: playerGain(for: next))
      try incoming.start(atFrame: 0)

      let outgoing = activePlayback
      let listened = listenedSeconds()

      // Equal power on both halves: two tracks are audible together here,
      // and linear ramps would sum to a hole in the middle of the crossover.
      graph.fade(graph.idleVoice, to: 1, over: duration, curve: .equalPower)
      graph.fade(graph.activeVoice, to: 0, over: duration, curve: .equalPower) { [weak self] in
        outgoing?.stop()
        self?.incomingPlayback = nil
      }

      // Halfway through is when the incoming track becomes the one being heard,
      // so that is when it becomes the one being reported.
      DispatchQueue.main.asyncAfter(deadline: .now() + duration / 2) { [weak self] in
        guard let self else { return }
        self.graph.swapVoices()
        self.activePlayback = incoming
        self.activeReader = reader
        self.queue.set(self.queue.tracks, startIndex: self.queue.activeIndex + 1)
        // The incoming track has been audible since the fade began, half a
        // fade ago, so it starts with that much already listened rather than
        // from zero.
        self.listenedAccumulated = duration / 2
        self.listeningSince = self.now()
        self.transitioning = false
        self.emit(.trackChanged(index: self.queue.activeIndex, id: next.id,
                                previousListenedSec: listened))
        self.publishNowPlaying()
      }
    } catch {
      transitioning = false
      emit(.failed(String(describing: error)))
    }
  }

  private func cancelTransition() {
    guard transitioning else { return }
    transitioning = false
    incomingPlayback?.stop()
    incomingPlayback = nil
    incomingTrack = nil
    graph.cut(graph.idleVoice, to: 0)
    // And the active voice back to full. It was part-way through fading *out*
    // when the fade was abandoned, and leaving it there means the track that
    // goes on playing is quieter than it should be — audible after a seek
    // during a crossfade, and left behind by a skip for the whole next track.
    graph.cut(graph.activeVoice, to: 1)
  }

  // MARK: - Bookkeeping

  /// Played time for the outgoing track, fade included, pauses excluded.
  /// See `Event.trackChanged`.
  private func listenedSeconds() -> Double? {
    guard listeningSince != nil || listenedAccumulated > 0 else { return nil }
    let open = listeningSince.map { now().timeIntervalSince($0) } ?? 0
    return listenedAccumulated + open
  }

  private func finish() {
    stopEverything()
    state = .ended
    nowPlaying.clear()
    emit(.ended)
  }

  private func stopEverything() {
    cancelTransition()
    activePlayback?.stop()
    activePlayback = nil
    activeReader = nil
    stopTicking()
  }

  private func startTicking() {
    stopTicking()
    // Four times a second: fast enough that a crossfade starts within a frame
    // of where it should, cheap enough to leave running.
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    ticker = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopTicking() {
    ticker?.invalidate()
    ticker = nil
  }

  private func emit(_ event: Event) {
    onEvent?(event)
  }
}
