package dev.yuzic.engine

/**
 * The queue, and the rules about what happens between one track and the next.
 *
 * This is native for the reason given everywhere else in this project: when the
 * app is backgrounded its JavaScript stops, and the transition still has to
 * happen. Anything decided up in JS is a decision that will one day not get made,
 * usually in a car.
 *
 * A direct port of `ios/PlaybackQueue.swift`, and deliberately a dull one. The
 * transition rules below are the observable behaviour of the product, not an
 * iOS implementation detail, so the two files are kept close enough that a
 * change to one reads as an obvious omission in the other.
 */
class PlaybackQueue {

  var tracks: List<TrackRecord> = emptyList()
    private set

  var activeIndex: Int = 0
    private set

  var crossfade: CrossfadeRecord? = null
  var sampleRateMode: String = "fixed"

  fun set(tracks: List<TrackRecord>, startIndex: Int) {
    this.tracks = tracks
    this.activeIndex = startIndex.coerceIn(0, maxOf(0, tracks.size - 1))
  }

  fun append(more: List<TrackRecord>) {
    tracks = tracks + more
  }

  val activeTrack: TrackRecord?
    get() = tracks.getOrNull(activeIndex)

  val nextTrack: TrackRecord?
    get() = tracks.getOrNull(activeIndex + 1)

  /**
   * How long the transition out of the current track should take, in seconds.
   * Zero means cut.
   *
   * Four rules, none of them configurable, because each one is a bug rather than
   * a preference when it goes the other way:
   *
   * - A stream with no end cannot fade into anything. There is no known finish
   *   line to start the fade before.
   * - A track marked as following the one before it was mastered to run straight
   *   out of it. Fading across a deliberate segue doubles the overlap and sounds
   *   worse than the join it is trying to smooth.
   * - A manual skip is immediate. A fade is for a track that ended; when someone
   *   presses next they want it now, and eight seconds of politeness reads as lag.
   * - The fade is clamped to half the shorter track. An eight second crossfade
   *   across a three second interlude would consume the whole thing.
   */
  fun transitionDuration(userInitiated: Boolean): Double {
    val crossfade = this.crossfade ?: return 0.0
    if (crossfade.durationSec <= 0.0) return 0.0

    val current = activeTrack ?: return 0.0
    if (current.continuous) return 0.0

    val next = nextTrack ?: return 0.0
    if (next.continuous) return 0.0

    if (userInitiated && crossfade.skipIsImmediate) return 0.0
    if (crossfade.mode == "gapless-aware" && next.followsPrevious) return 0.0

    // An absent duration means "the host does not know yet", not "zero". Swift
    // spells that .infinity so the min() falls through to the other track;
    // Kotlin needs it said out loud, but the arithmetic is the same and an
    // unknown duration must never clamp the fade to nothing.
    val shortest = minOf(
      current.durationSec ?: Double.POSITIVE_INFINITY,
      next.durationSec ?: Double.POSITIVE_INFINITY,
    )
    if (!shortest.isFinite()) return crossfade.durationSec
    return minOf(crossfade.durationSec, shortest / 2.0)
  }
}
