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
    case progress(positionSec: Double, durationSec: Double)
    case ended
    case failed(String)
  }

  public enum PlaybackState: String {
    case idle, buffering, playing, paused, ended
  }

  private let graph: AudioGraph
  private let factory: TrackReaderFactory
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

  public init(graph: AudioGraph, factory: TrackReaderFactory) {
    self.graph = graph
    self.factory = factory
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
      activePlayback?.resume()
      state = .playing
      startTicking()
    }
  }

  public func pause() {
    activePlayback?.pause()
    incomingPlayback?.pause()
    state = .paused
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

    graph.cut(graph.activeVoice, to: 1)
    try playback.start(atFrame: frame)
    trackStartedAt = Date()

    state = .playing
    emit(.trackChanged(index: index, id: track.id, previousListenedSec: previousListenedSec))
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

  private func tick() {
    guard let playback = activePlayback, let reader = activeReader, reader.sampleRate > 0 else { return }
    let position = Double(playback.currentFrame) / reader.sampleRate
    let duration = Double(reader.totalFrames) / reader.sampleRate
    emit(.progress(positionSec: position, durationSec: duration))

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
