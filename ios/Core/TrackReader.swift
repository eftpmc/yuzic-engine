import AVFoundation

/**
 A source of decoded audio, whatever decoded it.

 The engine had exactly one reader — `AudioFileReader`, over Core Audio — and
 named the concrete type everywhere. That is fine while every format the app
 plays is one Core Audio understands, and it stops being fine the moment one
 is not: iOS has no Vorbis or Opus decoder, so an Ogg file cannot be opened at
 all and the track fails outright rather than degrading.

 This is the seam a second decoder slots into. Deliberately small — nine
 members, taken from what the engine actually calls rather than from
 `AudioFileReader`'s full surface — because everything in it has to be
 implemented again by hand for every format added.

 Frames are *source* frames throughout, at `sampleRate`. A decoder that works
 in some other unit converts at this boundary, so the queue, the progress
 accessor and the crossfade scheduler never have to know which decoder is
 underneath.
 */
public protocol TrackReader: AnyObject {

  /// Total length in source frames, or 0 while unknown — a stream with no
  /// finish line reports 0 rather than guessing, and the engine draws no
  /// progress bar for it.
  var totalFrames: Int64 { get }

  /// Source frames per second. Zero until `open` has succeeded, which is what
  /// callers guard on before dividing by it.
  var sampleRate: Double { get }

  /// Read enough of the container to answer the two properties above.
  /// Idempotent: the factory opens a reader before handing it over and the
  /// engine opens it again, and neither should have to know about the other.
  func open() throws

  func seek(toFrame frame: Int64) throws

  /// The next block, or nil at the end of the stream. Fewer frames than asked
  /// for is normal and is not an end-of-stream signal.
  func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer?

  /// How much beyond `frame` is already fetched, in source frames. Feeds the
  /// buffered figure the progress bar draws, so it is measured on the same
  /// timeline as the position rather than from the playhead.
  func bufferedFramesAhead(ofFrame frame: Int64) -> Int64

  /// Abandon in-flight network reads. Used before a seek, so a fetch for the
  /// old position cannot land after the new one has started.
  func cancelPendingReads()

  func resumePendingReads()
}
