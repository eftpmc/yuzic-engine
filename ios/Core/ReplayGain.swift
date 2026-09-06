import Foundation

/**
 Loudness normalisation, from tags the host supplies.

 The engine never computes loudness itself. Measuring a track means decoding
 all of it, which is exactly the thing this player is built not to do — and the
 figures are already in the files, put there by whatever tagged the library.

 Everything here is arithmetic over a `Track`, which is the point: the decision
 of how loud something plays is worth being able to test without a graph, and
 the graph is left with nothing to do but set a number.
 */
public enum ReplayGainMode: String {
  case off
  case track
  case album
  /// Album gain when the queue is an album in order, track gain otherwise.
  /// A shuffled playlist wants every track at the same loudness; an album
  /// wants the quiet intro to stay quiet.
  case auto
}

public struct ReplayGainSettings: Equatable {
  public let mode: ReplayGainMode
  public let preampDb: Double
  /**
   Applied to tracks with no tags at all.

   Left at zero by default. A library where half the tracks are adjusted and
   half are not sounds *more* uneven than one where none are — this exists so
   someone can match the two, not because a guess is a good idea.
   */
  public let untaggedPreampDb: Double
  /// Hold total gain below clipping using the track's sample peak.
  public let preventClipping: Bool

  public init(
    mode: ReplayGainMode,
    preampDb: Double = 0,
    untaggedPreampDb: Double = 0,
    preventClipping: Bool = true
  ) {
    self.mode = mode
    self.preampDb = preampDb
    self.untaggedPreampDb = untaggedPreampDb
    self.preventClipping = preventClipping
  }

  public static let off = ReplayGainSettings(mode: .off)
}

public enum ReplayGain {

  /**
   The linear gain to apply to a track, 1.0 being unchanged.

   Two things here are easy to get wrong and unpleasant to listen to.

   **Clipping.** Replay gain is usually a *reduction*, but not always: a quiet
   master gets a positive figure, and applying it to a track whose peak is
   already near full scale pushes samples past it. The result is distortion
   introduced by the feature meant to make things sound better. When the peak
   is known, the gain is held to what the peak allows — quieter than asked for
   beats distorted.

   **An absent tag is not a tag of zero.** A track with no figure gets the
   untagged preamp, which is a different setting with a different default,
   because "leave this alone" and "this needs no adjustment" are different
   statements about a file.
   */
  public static func linearGain(for track: Track, settings: ReplayGainSettings) -> Float {
    guard settings.mode != .off else { return 1.0 }

    let db: Double
    if let tagged = track.replayGainDb {
      db = tagged + settings.preampDb
    } else {
      db = settings.untaggedPreampDb
    }

    var gain = pow(10.0, db / 20.0)

    if settings.preventClipping, let peak = track.replayGainPeak, peak > 0 {
      // Only ever reduces. A peak below full scale leaves headroom, but using
      // it to *raise* a track past its tag would be inventing loudness the
      // tags did not ask for.
      gain = min(gain, 1.0 / peak)
    }

    // A tag can be absurd — broken taggers write figures like -60 dB, and one
    // silent track in a library is reported as a bug in the player, not in the
    // file. The ceiling is the clipping guard's job; this is the floor.
    return Float(max(gain, 0.05))
  }
}
