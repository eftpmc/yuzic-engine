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
}

extension CachedByteSource: ByteSource {}
