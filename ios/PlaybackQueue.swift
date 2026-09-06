import Foundation

/**
 The queue, and the rules about what happens between one track and the next.

 This is native for the reason given everywhere else in this project: when the
 app is backgrounded its JavaScript stops, and the transition still has to
 happen. Anything decided up in JS is a decision that will one day not get made,
 usually in a car.
 */
final class PlaybackQueue {

  private(set) var tracks: [TrackRecord] = []
  private(set) var activeIndex: Int = 0

  var crossfade: CrossfadeRecord?
  var sampleRateMode: String = "fixed"

  func set(_ tracks: [TrackRecord], startIndex: Int) {
    self.tracks = tracks
    self.activeIndex = max(0, min(startIndex, max(0, tracks.count - 1)))
  }

  func append(_ more: [TrackRecord]) {
    tracks.append(contentsOf: more)
  }

  var activeTrack: TrackRecord? {
    tracks.indices.contains(activeIndex) ? tracks[activeIndex] : nil
  }

  var nextTrack: TrackRecord? {
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
  func transitionDuration(userInitiated: Bool) -> TimeInterval {
    guard let crossfade, crossfade.durationSec > 0 else { return 0 }
    guard let current = activeTrack, !current.continuous else { return 0 }
    guard let next = nextTrack, !next.continuous else { return 0 }

    if userInitiated && crossfade.skipIsImmediate { return 0 }
    if crossfade.mode == "gapless-aware" && next.followsPrevious { return 0 }

    let shortest = min(current.durationSec ?? .infinity, next.durationSec ?? .infinity)
    guard shortest.isFinite else { return crossfade.durationSec }
    return min(crossfade.durationSec, shortest / 2)
  }
}
