import Foundation
import AVFoundation

/// Opens a decodable stream for a track. Injected so the engine can be driven
/// from fixtures in a test without a network, and so the choice between the two
/// transports lives in one place rather than inside the engine.
public protocol TrackReaderFactory {
  func makeReader(for track: Track) throws -> AudioFileReader
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
  private var activeReader: AudioFileReader?

  private var ticker: Timer?
  private var transitioning = false
  private var trackStartedAt: Date?

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
      guard replayGain != oldValue, let track = queue.activeTrack else { return }
      graph.setTrackGain(graph.activeVoice, to: ReplayGain.linearGain(for: track, settings: replayGain))
    }
  }

  public init(
    graph: AudioGraph,
    factory: TrackReaderFactory,
    nowPlaying: NowPlayingCenter = NowPlayingCenter()
  ) {
    self.graph = graph
    self.factory = factory
    self.nowPlaying = nowPlaying
    wireRemoteCommands()
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
    didSet { if remoteCommands != oldValue { wireRemoteCommands() } }
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
      return
    }
    let sampleRate = reader.sampleRate > 0 ? reader.sampleRate : 44_100
    let position = Double(activePlayback?.currentFrame ?? 0) / sampleRate
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

  deinit { ticker?.invalidate() }

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
      state = .playing
      publishNowPlaying()
      startTicking()
    }
  }

  public func pause() {
    activePlayback?.pause()
    incomingPlayback?.pause()
    state = .paused
    publishNowPlaying()
    stopTicking()
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
    activePlayback?.stop()
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    playback.onEndOfTrack = { [weak self] in self?.handleTrackFinished() }
    activePlayback = playback
    try playback.start(atFrame: frame)
    state = .playing
    // A seek moves the fix point, so the lock screen has to be told or its
    // timer carries on from where the track used to be.
    publishNowPlaying()
    startTicking()
  }

  public func skipToNext() throws {
    try move(to: queue.activeIndex + 1, userInitiated: true)
  }

  public func skipToPrevious() throws {
    try move(to: queue.activeIndex - 1, userInitiated: true)
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
    // A skip is a cut, not a fade — `transitionDuration` says so, and here it
    // is honoured by not starting one at all.
    graph.cut(graph.activeVoice, to: 0)
    activePlayback?.stop()

    queue.set(queue.tracks, startIndex: index)
    try beginTrack(at: index, fromFrame: 0, previousListenedSec: listened)
  }

  private func beginTrack(at index: Int, fromFrame frame: Int64,
                          previousListenedSec: Double? = nil) throws {
    guard let track = queue.tracks.indices.contains(index) ? queue.tracks[index] : nil else {
      finish()
      return
    }

    state = .buffering
    let reader = try factory.makeReader(for: track)
    try reader.open()

    // The idle voice may be connected at some other track's rate; a connection
    // cannot be reconfigured while it is playing, which is why this happens
    // here rather than at the crossover.
    graph.reconnectIdleVoice(toSourceRate: reader.sampleRate)

    activeReader = reader
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    playback.onEndOfTrack = { [weak self] in self?.handleTrackFinished() }
    activePlayback = playback

    graph.setTrackGain(graph.activeVoice, to: ReplayGain.linearGain(for: track, settings: replayGain))
    graph.cut(graph.activeVoice, to: 1)
    try playback.start(atFrame: frame)
    trackStartedAt = Date()

    state = .playing
    emit(.trackChanged(index: index, id: track.id, previousListenedSec: previousListenedSec))
    publishNowPlaying()
    startTicking()
  }

  /// Called when a track runs out with no crossfade to carry it.
  private func handleTrackFinished() {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.transitioning else { return }
      let listened = self.listenedSeconds()
      let next = self.queue.activeIndex + 1
      guard self.queue.tracks.indices.contains(next) else { self.finish(); return }
      self.queue.set(self.queue.tracks, startIndex: next)
      try? self.beginTrack(at: next, fromFrame: 0, previousListenedSec: listened)
    }
  }

  // MARK: - The crossfade

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
      // far as a duration draws a progress bar that lies.
      queue.activeTrack?.continuous == true ? 0 : Double(reader.totalFrames) / reader.sampleRate,
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

    guard !transitioning else { return }
    let fade = queue.transitionDuration(userInitiated: false)
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
      graph.setTrackGain(graph.idleVoice, to: ReplayGain.linearGain(for: next, settings: replayGain))
      try incoming.start(atFrame: 0)

      let outgoing = activePlayback
      let listened = listenedSeconds()

      graph.fade(graph.idleVoice, to: 1, over: duration)
      graph.fade(graph.activeVoice, to: 0, over: duration) { [weak self] in
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
        self.trackStartedAt = Date().addingTimeInterval(-duration / 2)
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
    graph.cut(graph.idleVoice, to: 0)
  }

  // MARK: - Bookkeeping

  /// Played time for the outgoing track, fade included. See `Event.trackChanged`.
  private func listenedSeconds() -> Double? {
    guard let startedAt = trackStartedAt else { return nil }
    return Date().timeIntervalSince(startedAt)
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
