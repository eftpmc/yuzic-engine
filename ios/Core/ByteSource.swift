import Foundation

/**
 What the reader needs from wherever the bytes live.

 Two implementations, because there turned out to be two transports rather than
 one — see docs/architecture.md §10. A direct stream is ranged and its length is
 known, so `CachedByteSource` can serve any offset on demand. A transcoded
 stream refuses ranges, declines to state a length, and is produced as it is
 sent, so `StreamingByteSource` can only ever serve what has already arrived.

 The reader above does not care which it has. It asks for bytes at an offset and
 either gets them or waits — the difference between the two is how long the wait
 is, and whether a forward seek is a read or a reconnection.
 */
public protocol ByteSource: AnyObject {
  /// The size the audio parser is told. Exact where it can be known; an
  /// estimate on a stream that has not finished.
  func totalBytes() throws -> Int64

  /// Blocking. Returns fewer bytes than asked only at the true end.
  func read(offset: Int64, count: Int) throws -> Data

  /// Contiguous bytes available from `offset` without waiting.
  func availableBytes(from offset: Int64) -> Int64

  /// Unblocks any waiting read. A seek cancels what is in flight.
  func cancel()
  func resume()

  /**
   Whether this source can only be read forwards, in the order bytes arrive.

   True for the transcoded transport and false for everything else. It is not
   a detail the parsers care about — they read where they read and this waits
   or fetches — but it decides what *recovery* means, and there the two are
   opposites. A ranged source that fails can be asked for the same bytes
   again, so retrying the read is the whole fix. A sequential one cannot: the
   bytes were coming from a producer that has now stopped, and reading again
   waits on a stream nobody is sending. Recovering there means asking the
   server for a *new* stream from the position reached, which is a different
   byte stream and therefore a different reader.

   Distinguished here rather than by testing the concrete type, so a reader
   can forward it without knowing which sources exist.
   */
  var isSequential: Bool { get }

  /**
   Whether the length this source reports is a fact rather than a guess.

   Only meaningful for a sequential source, and only false while one is still
   streaming: a transcoded response arrives with no `Content-Length`, so
   `totalBytes()` answers `duration × bitrate` until the producer says it has
   finished, at which point the real byte count is known.

   It exists because "an empty read at the reported length" means opposite
   things either side of that line. Against a known length it is the end of
   the file. Against an estimate it means only that the bytes have not arrived
   — and reading it as an ending is how a track ends itself early, silently,
   which the engine then follows by advancing the queue.
   */
  var isFinished: Bool { get }
}

public extension ByteSource {
  /// Seekable unless a source says otherwise: the ranged transport is the
  /// normal case and the sequential one is the exception that has to declare
  /// itself.
  var isSequential: Bool { false }

  /// A source whose length came from the server is never mid-guess. Only the
  /// sequential transport has to answer this for real.
  var isFinished: Bool { true }
}

extension CachedByteSource: ByteSource {}
