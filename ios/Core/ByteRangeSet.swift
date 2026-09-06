import Foundation

/**
 Which byte ranges of a file are actually present.

 The cache holds files with holes in them — that is the whole point of the
 design in §2 of the architecture doc — so "do we have these bytes?" has to be
 answerable cheaply and exactly. Getting it slightly wrong is the kind of bug
 that shows up as a click in the audio once in a while and is then very hard to
 find, so this is kept pure and tested rather than folded into the file handle.

 Ranges are half-open: `0..<10` is ten bytes, and touching ranges are merged so
 the set stays small no matter what order the fetches complete in.
 */
public struct ByteRangeSet: Equatable {
  /// Sorted, non-overlapping, non-adjacent.
  public private(set) var ranges: [Range<Int64>] = []

  public init() {}

  public init(_ ranges: [Range<Int64>]) {
    for range in ranges { insert(range) }
  }

  public var isEmpty: Bool { ranges.isEmpty }

  public var totalBytes: Int64 {
    ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
  }

  public mutating func insert(_ range: Range<Int64>) {
    guard !range.isEmpty else { return }

    var merged = range
    var result: [Range<Int64>] = []
    result.reserveCapacity(ranges.count + 1)

    for existing in ranges {
      // Adjacent counts as overlapping: 0..<10 and 10..<20 are one range of
      // twenty bytes, and keeping them apart would grow the set without bound
      // on a sequential download.
      if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
        result.append(existing)
      } else {
        merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
      }
    }

    result.append(merged)
    result.sort { $0.lowerBound < $1.lowerBound }
    ranges = result
  }

  /// True only when *every* byte of `range` is present.
  public func contains(_ range: Range<Int64>) -> Bool {
    guard !range.isEmpty else { return true }
    for existing in ranges where existing.lowerBound <= range.lowerBound {
      if existing.upperBound >= range.upperBound { return true }
    }
    return false
  }

  /**
   How many contiguous bytes are available starting at `offset`.

   This is what decides whether a read can be served now or has to wait, and —
   with a bitrate — what the progress bar reports as buffered.
   */
  public func contiguousBytes(from offset: Int64) -> Int64 {
    for existing in ranges where existing.lowerBound <= offset && existing.upperBound > offset {
      return existing.upperBound - offset
    }
    return 0
  }

  /// The first gap at or after `offset`, bounded by `limit`. Nil when the whole
  /// span is already present.
  public func firstGap(from offset: Int64, limit: Int64) -> Range<Int64>? {
    guard offset < limit else { return nil }
    var cursor = offset
    for existing in ranges where existing.upperBound > cursor {
      if existing.lowerBound > cursor {
        return cursor..<min(existing.lowerBound, limit)
      }
      cursor = existing.upperBound
      if cursor >= limit { return nil }
    }
    return cursor < limit ? cursor..<limit : nil
  }
}
