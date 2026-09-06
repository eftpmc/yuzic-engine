package dev.yuzic.engine

import kotlin.math.min
import kotlin.math.pow

/**
 * Loudness normalisation, from tags the host supplies.
 *
 * A direct port of `ios/Core/ReplayGain.swift`. Kept arithmetic-only and free
 * of any player type for the same reason the Swift is: how loud something
 * plays is worth being able to reason about without a graph, and the graph is
 * left with nothing to do but set a number.
 *
 * The engine never computes loudness itself. Measuring a track means decoding
 * all of it, which is exactly the thing this player is built not to do — and
 * the figures are already in the files, put there by whatever tagged the
 * library.
 */
enum class ReplayGainMode(val raw: String) {
  OFF("off"),
  TRACK("track"),
  ALBUM("album"),

  /**
   * Album gain when the queue is an album in order, track gain otherwise. A
   * shuffled playlist wants every track at the same loudness; an album wants
   * the quiet intro to stay quiet.
   */
  AUTO("auto");

  companion object {
    fun from(raw: String?): ReplayGainMode =
      entries.firstOrNull { it.raw == raw } ?: OFF
  }
}

data class ReplayGainSettings(
  val mode: ReplayGainMode,
  val preampDb: Double = 0.0,
  /**
   * Applied to tracks with no tags at all.
   *
   * Left at zero by default. A library where half the tracks are adjusted and
   * half are not sounds *more* uneven than one where none are — this exists so
   * someone can match the two, not because a guess is a good idea.
   */
  val untaggedPreampDb: Double = 0.0,
  /** Hold total gain below clipping using the track's sample peak. */
  val preventClipping: Boolean = true,
) {
  companion object {
    val OFF = ReplayGainSettings(mode = ReplayGainMode.OFF)
  }
}

object ReplayGain {

  /**
   * The linear gain to apply to a track, 1.0 being unchanged.
   *
   * Two things here are easy to get wrong and unpleasant to listen to.
   *
   * **Clipping.** Replay gain is usually a *reduction*, but not always: a quiet
   * master gets a positive figure, and applying it to a track whose peak is
   * already near full scale pushes samples past it. The result is distortion
   * introduced by the feature meant to make things sound better. When the peak
   * is known, the gain is held to what the peak allows — quieter than asked
   * for beats distorted.
   *
   * **An absent tag is not a tag of zero.** A track with no figure gets the
   * untagged preamp, which is a different setting with a different default,
   * because "leave this alone" and "this needs no adjustment" are different
   * statements about a file.
   *
   * Note that `TRACK`, `ALBUM` and `AUTO` currently behave alike, here and on
   * iOS: `Track` carries one gain figure, not a pair, so there is nothing yet
   * for the mode to choose between. The distinction is kept in the type
   * because the tags exist in the files and the day the host sends both, this
   * is where the choice belongs.
   */
  fun linearGain(track: TrackRecord, settings: ReplayGainSettings): Float {
    if (settings.mode == ReplayGainMode.OFF) return 1.0f

    val tagged = track.replayGainDb
    val db = if (tagged != null) tagged + settings.preampDb else settings.untaggedPreampDb

    var gain = 10.0.pow(db / 20.0)

    val peak = track.replayGainPeak
    if (settings.preventClipping && peak != null && peak > 0) {
      // Only ever reduces. A peak below full scale leaves headroom, but using
      // it to *raise* a track past its tag would be inventing loudness the
      // tags did not ask for.
      gain = min(gain, 1.0 / peak)
    }

    // A tag can be absurd — broken taggers write figures like -60 dB, and one
    // silent track in a library is reported as a bug in the player, not in the
    // file. The ceiling is the clipping guard's job; this is the floor.
    return maxOf(gain, 0.05).toFloat()
  }
}
