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

  public init() {}

  public func set(_ tracks: [Track], startIndex: Int) {
    self.tracks = tracks
    self.activeIndex = max(0, min(startIndex, max(0, tracks.count - 1)))
  }

  public func append(_ more: [Track]) {
    tracks.append(contentsOf: more)
  }

  public var activeTrack: Track? {
    tracks.indices.contains(activeIndex) ? tracks[activeIndex] : nil
  }

  public var nextTrack: Track? {
    let next = activeIndex + 1
    return tracks.indices.contains(next) ? tracks[next] : nil
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
