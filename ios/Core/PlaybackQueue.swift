import Foundation

/**
 The queue, and the rules about what happens between one track and the next.

 This is native for the reason given everywhere else in this project: when the
 app is backgrounded its JavaScript stops, and the transition still has to
 happen. Anything decided up in JS is a decision that will one day not get made,
 usually in a car.

 `src/transitionDuration.ts` is the specification these rules answer to, and
 `Tests/CoreTests` runs the same table of cases against this implementation.
 */
public final class PlaybackQueue {

  public private(set) var tracks: [Track] = []
  public private(set) var activeIndex: Int = 0

  public var crossfade: CrossfadeSettings?
  public var sampleRateMode: SampleRateMode = .fixed
  public var repeatMode: RepeatMode = .off

  public init() {}

  public func set(_ tracks: [Track], startIndex: Int) {
    self.tracks = tracks
    self.activeIndex = max(0, min(startIndex, max(0, tracks.count - 1)))
  }

  public func append(_ more: [Track]) {
    tracks.append(contentsOf: more)
  }

  // MARK: - Editing
  //
  // One rule governs all of these: **the active index keeps pointing at the
  // same track**. Someone reordering a queue is not asking for the music to
  // jump, and a player that changes what is playing because a row moved
  // somewhere else in the list is broken in a way people notice immediately.
  // Every index adjustment below exists to hold that still.

  /// Insert before `index`. Clamped, so an out-of-range index appends rather
  /// than throwing — a queue edit is not worth failing a call over.
  public func insert(_ more: [Track], at index: Int) {
    guard !more.isEmpty else { return }
    let at = max(0, min(index, tracks.count))
    tracks.insert(contentsOf: more, at: at)
    if at <= activeIndex { activeIndex += more.count }
  }

  /**
   Remove one item.

   Removing the *playing* track is the interesting case, and the index stays
   where it is: whatever followed slides into place, which is what "remove this
   from the queue" means to someone looking at a list. The caller is left to
   notice that `activeTrack` changed identity and restart playback — the queue
   does not start or stop anything, here or anywhere else.
   */
  public func remove(at index: Int) {
    guard tracks.indices.contains(index) else { return }
    tracks.remove(at: index)
    if index < activeIndex {
      activeIndex -= 1
    }
    activeIndex = max(0, min(activeIndex, max(0, tracks.count - 1)))
  }

  public func move(from: Int, to: Int) {
    guard tracks.indices.contains(from) else { return }
    let destination = max(0, min(to, tracks.count - 1))
    guard from != destination else { return }

    let moving = tracks.remove(at: from)
    tracks.insert(moving, at: destination)

    // Three cases, and only the first is about the moved item itself.
    if from == activeIndex {
      activeIndex = destination
    } else if from < activeIndex && destination >= activeIndex {
      activeIndex -= 1
    } else if from > activeIndex && destination <= activeIndex {
      activeIndex += 1
    }
  }

  public func clear() {
    tracks = []
    activeIndex = 0
  }

  public var activeTrack: Track? {
    tracks.indices.contains(activeIndex) ? tracks[activeIndex] : nil
  }

  /**
   Which index plays after this one, honouring repeat.

   Separate from `nextTrack` because the crossfade machinery needs to preload
   whatever is coming, and under `.one` that is the track already playing —
   a second reader on the same source, which is exactly what a repeat-one
   crossfade is. Returning nil there instead would silently disable the fade
   for the one case where the fade is most obvious.
   */
  public var nextIndex: Int? {
    guard !tracks.isEmpty else { return nil }
    switch repeatMode {
    case .one:
      return activeIndex
    case .all:
      return (activeIndex + 1) % tracks.count
    case .off:
      let next = activeIndex + 1
      return tracks.indices.contains(next) ? next : nil
    }
  }

  /**
   Where a *user-initiated* next lands, which is not always where an automatic
   advance lands.

   `nextIndex` answers "what plays when this track ends", and under `.one` that
   is this track again. A person pressing next has asked to leave it, so a skip
   advances instead. Under `.all` both wrap, and that is the case this exists
   for: `activeIndex + 1` on the last track is out of range, which the engine
   reads as the queue finishing — so the same queue in the same repeat mode
   wrapped when the track ended by itself and stopped when the user pressed
   next.

   Under `.off` this deliberately returns an index past the end on the last
   track, because finishing is what should happen there.
   */
  public var skipNextIndex: Int {
    guard !tracks.isEmpty else { return 0 }
    let next = activeIndex + 1
    return repeatMode == .all ? next % tracks.count : next
  }

  public var nextTrack: Track? {
    guard let next = nextIndex, tracks.indices.contains(next) else { return nil }
    return tracks[next]
  }

  /**
   How long the transition out of the current track should take, in seconds.
   Zero means cut.

   Four rules, none of them configurable, because each one is a bug rather than
   a preference when it goes the other way:

   - A stream with no end cannot fade into anything. There is no known finish
     line to start the fade before.
   - A track marked as following the one before it was mastered to run straight
     out of it. Fading across a deliberate segue doubles the overlap and sounds
     worse than the join it is trying to smooth.
   - A manual skip is immediate. A fade is for a track that ended; when someone
     presses next they want it now, and eight seconds of politeness reads as lag.
   - The fade is clamped to half the shorter track. An eight second crossfade
     across a three second interlude would consume the whole thing.
   */
  public func transitionDuration(userInitiated: Bool) -> TimeInterval {
    transitionDuration(from: activeTrack, to: nextTrack, userInitiated: userInitiated)
  }

  /// Exposed separately so the rules can be exercised without standing a queue
  /// up around them — the conformance table drives this form directly.
  public func transitionDuration(
    from current: Track?,
    to next: Track?,
    userInitiated: Bool
  ) -> TimeInterval {
    guard let crossfade, crossfade.durationSec > 0 else { return 0 }
    guard let current, !current.continuous else { return 0 }
    guard let next, !next.continuous else { return 0 }

    if userInitiated && crossfade.skipIsImmediate { return 0 }
    if crossfade.mode == .gaplessAware && next.followsPrevious { return 0 }

    // An absent duration means "the host does not know yet", not "zero", so it
    // must not clamp the fade away.
    let shortest = min(
      current.durationSec ?? .infinity,
      next.durationSec ?? .infinity
    )
    guard shortest.isFinite else { return crossfade.durationSec }
    return min(crossfade.durationSec, shortest / 2)
  }
}
