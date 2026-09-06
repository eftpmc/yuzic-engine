import Foundation
import AVFoundation

/**
 Keeps one player node fed.

 The reader blocks — it has to, since `AudioFile_ReadProc` has no async form —
 so decoding happens on its own queue and never on the render thread. What this
 class does is keep a couple of seconds of PCM scheduled ahead, so a slow
 network read costs buffer-ahead rather than a dropout.

 Scheduling is driven by completion rather than a timer: every buffer handed to
 the node carries a callback asking for the next one. The depth is then
 self-correcting — slow decoding drains the queue and refills as fast as it can,
 fast decoding leaves it at target with the thread asleep.
 */
public final class TrackPlayback {

  /// Half a second each, four deep: two seconds of slack. Enough to ride out a
  /// window fetch on a slow connection, short enough that a stop takes effect
  /// promptly.
  public static let bufferFrames: AVAudioFrameCount = 22_050
  public static let targetBuffersAhead = 4

  private let reader: AudioFileReader
  private let voice: AudioGraph.Voice
  private let queue: DispatchQueue
  private let lock = NSLock()

  private var scheduledAhead = 0
  private var stopped = false
  private var reachedEnd = false
  private var startFrameValue: Int64 = 0

  /// Fires once the last scheduled buffer has played out.
  public var onEndOfTrack: (() -> Void)?

  public init(reader: AudioFileReader, voice: AudioGraph.Voice, label: String = "decode") {
    self.reader = reader
    self.voice = voice
    self.queue = DispatchQueue(label: "dev.yuzic.engine.\(label)", qos: .userInitiated)
  }

  public var startFrame: Int64 {
    lock.lock(); defer { lock.unlock() }
    return startFrameValue
  }

  /**
   Where playback has actually reached, in frames from the start of the track.

   Derived from the node's own render time rather than counted on the way in:
   what has been *scheduled* runs ahead of what has been *heard* by exactly the
   buffer depth, and reporting the former would put the progress bar two seconds
   into the future.
   */
  public var currentFrame: Int64 {
    // `playerTime(forNodeTime:)` is not merely optional-returning: it asserts
    // that the time it is handed carries a valid sample or host time, and
    // `lastRenderTime` returns one with neither in the window between starting
    // a node and its first render. Passing that straight through traps —
    // a hard crash, not a nil — and the window is exactly when the lock screen
    // asks for a position.
    guard let nodeTime = voice.player.lastRenderTime,
          nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
          let playerTime = voice.player.playerTime(forNodeTime: nodeTime) else {
      return startFrame
    }
    return startFrame + playerTime.sampleTime
  }

  public func start(atFrame frame: Int64 = 0) throws {
    lock.lock()
    stopped = false
    reachedEnd = false
    scheduledAhead = 0
    startFrameValue = frame
    lock.unlock()

    try reader.seek(toFrame: frame)
    fill()
    voice.player.play()
  }

  public func pause() { voice.player.pause() }

  public func resume() {
    voice.player.play()
    // A long pause can drain the queue; top it up rather than waiting for a
    // completion callback that is never going to arrive.
    fill()
  }

  /**
   Stop feeding the node, and unblock the decode thread if it is waiting.

   `stopped` is set before the node is stopped so the completion handlers that
   `stop()` fires for the flushed buffers see it and do not schedule more.

   The cancel is what makes this prompt. Without it a producer parked in a
   network read stays parked — holding a thread and a request open until the
   HTTP timeout, long after nothing wants the audio. It does not wait for that
   to happen: the thread unwinds on its own, and this playback is being
   discarded either way.
   */
  public func stop() {
    lock.lock(); stopped = true; lock.unlock()
    voice.player.stop()
    reader.cancelPendingReads()
  }

  /**
   Stop, and do not return until the decode thread has actually unwound.

   For the one case where the difference matters: a seek builds a new
   `TrackPlayback` over the *same* reader, and `AudioFileReader` is explicitly
   not thread-safe. Returning while the old producer is still inside
   `ExtAudioFileRead` would leave two threads in one reader, with the new one
   seeking it — which is undefined behaviour rather than a race that merely
   sounds bad.

   The queue is serial, so an empty block is a barrier: it runs only once the
   read in flight has returned. The reads are put back to work afterwards
   because the reader is about to be reused, and a cancelled source refuses
   everything.
   */
  public func stopAndWait() {
    stop()
    queue.sync {}
    reader.resumePendingReads()
  }

  /// Decode and schedule until the target depth is reached. Safe to call
  /// spuriously — it returns immediately when there is nothing to do.
  public func fill() {
    queue.async { [weak self] in
      guard let self else { return }

      while true {
        self.lock.lock()
        let idle = self.stopped || self.reachedEnd || self.scheduledAhead >= Self.targetBuffersAhead
        self.lock.unlock()
        if idle { return }

        let buffer: AVAudioPCMBuffer?
        do {
          buffer = try self.reader.read(frames: Self.bufferFrames)
        } catch {
          // A read that fails mid-track ends what we can play. Whether that is
          // worth telling anyone about is a decision for the layer above.
          buffer = nil
        }

        guard let buffer, buffer.frameLength > 0 else {
          self.lock.lock(); self.reachedEnd = true; self.lock.unlock()
          self.notifyEndIfDrained()
          return
        }

        self.lock.lock(); self.scheduledAhead += 1; self.lock.unlock()

        self.voice.player.scheduleBuffer(buffer) { [weak self] in
          guard let self else { return }
          self.lock.lock(); self.scheduledAhead -= 1; self.lock.unlock()
          self.notifyEndIfDrained()
          self.fill()
        }
      }
    }
  }

  private func notifyEndIfDrained() {
    lock.lock()
    let done = reachedEnd && scheduledAhead <= 0 && !stopped
    if done { stopped = true }
    lock.unlock()
    if done { onEndOfTrack?() }
  }
}
