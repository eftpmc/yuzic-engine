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

  /** `off`, `one` or `all`, matching `RepeatMode` in `src/types.ts`. */
  var repeatMode: String = "off"

  fun set(tracks: List<TrackRecord>, startIndex: Int) {
    this.tracks = tracks
    this.activeIndex = startIndex.coerceIn(0, maxOf(0, tracks.size - 1))
  }

  fun append(more: List<TrackRecord>) {
    tracks = tracks + more
  }

  // MARK: - Editing
  //
  // One rule, and every method below serves it: the active index keeps pointing
  // at the same track. Each case is an off-by-one in a different direction, and
  // getting one wrong does not crash — it plays a different song, which gets
  // reported as "it randomly skips". Ported case-for-case from
  // `ios/Core/PlaybackQueue.swift`; `PlaybackQueueEditingTests.swift` is the
  // shared behaviour spec.

  /** Out of range appends rather than throwing — a host asking for "the end" is not an error. */
  fun insert(more: List<TrackRecord>, at: Int) {
    if (more.isEmpty()) return
    val index = at.coerceIn(0, tracks.size)
    tracks = tracks.subList(0, index) + more + tracks.subList(index, tracks.size)
    // `<=`, not `<`: "play this next" inserts *at* the playhead, and the track
    // already playing must be pushed down rather than displaced.
    if (index <= activeIndex) activeIndex += more.size
  }

  fun remove(at: Int) {
    if (at !in tracks.indices) return
    tracks = tracks.subList(0, at) + tracks.subList(at + 1, tracks.size)
    if (at < activeIndex) activeIndex -= 1
    // Removing the active track slides the next one into its place, so the
    // index is only clamped rather than moved. Emptying the queue leaves it at
    // 0 with nothing active, which `activeTrack` reports as null.
    activeIndex = activeIndex.coerceIn(0, maxOf(0, tracks.size - 1))
  }

  fun move(from: Int, to: Int) {
    if (from !in tracks.indices) return
    val destination = to.coerceIn(0, tracks.size - 1)
    if (from == destination) return

    val mutable = tracks.toMutableList()
    mutable.add(destination, mutable.removeAt(from))
    tracks = mutable

    // Three cases, and only the first is about the moved item itself.
    if (from == activeIndex) {
      activeIndex = destination
    } else if (from < activeIndex && destination >= activeIndex) {
      activeIndex -= 1
    } else if (from > activeIndex && destination <= activeIndex) {
      activeIndex += 1
    }
  }

  fun clear() {
    tracks = emptyList()
    activeIndex = 0
  }

  val activeTrack: TrackRecord?
    get() = tracks.getOrNull(activeIndex)

  /**
   * Which track follows, honouring repeat.
   *
   * `one` returns the *active* index rather than null, so a crossfade still has
   * something to fade into — returning null there would silently disable the
   * fade for the one case where the overlap is most audible.
   */
  val nextIndex: Int?
    get() {
      if (tracks.isEmpty()) return null
      return when (repeatMode) {
        "one" -> activeIndex
        "all" -> (activeIndex + 1) % tracks.size
        else -> (activeIndex + 1).takeIf { it in tracks.indices }
      }
    }

  val nextTrack: TrackRecord?
    get() = nextIndex?.let { tracks.getOrNull(it) }

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
