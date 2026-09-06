import Foundation

/// Where bytes come from when the cache does not have them.
public protocol ByteFetcher: AnyObject {
  /// Total size of the resource. Asked once, and reported to the audio parser
  /// as the file's size even when almost none of it is on disk — see
  /// `CachedByteSource`.
  func contentLength() throws -> Int64
  /// Fetch exactly this range. Blocking; called off the render thread.
  func fetch(_ range: Range<Int64>) throws -> Data
}

public enum ByteSourceError: Error, Equatable {
  case cancelled
  case outOfBounds
  case fetchFailed(String)
}

/**
 A file with holes in it, that can answer a read at any offset.

 This is the thing the whole iOS design rests on. Core Audio's
 `AudioFile_ReadProc` hands us an *offset* rather than a cursor, and
 `AudioFile_GetSizeProc` is answered with the resource's true length even when
 nothing has been downloaded — so the parser believes it has a whole file, and
 a seek to the far end is an ordinary read rather than a special case. The spike
 in `spikes/ios-reader` confirmed that works: WAV and FLAC open and report the
 correct duration with only the first 30% present.

 Reads block. There is no async form of the read proc, so a miss means fetching
 the window and waiting. That is fine as long as it never happens on the render
 thread — a producer thread keeps PCM queued ahead, and a stall costs
 buffer-ahead rather than a dropout.

 Two behaviours here are not obvious and matter a great deal:

 - **Fetches are windowed and aligned**, not sized to the read. A parser asks
   for a few bytes at a time; issuing an HTTP request per read would be
   thousands of requests per track.
 - **MP4-family files get their tail fetched first.** `moov` sits at the end of
   a file that was not written faststart, and the spike showed the open failing
   outright without it — two of ALAC's first ten reads were past the fetched
   region. FLAC starts fine but cannot seek; M4A seeks fine but cannot start.
   Opposite failures, two mitigations.
 */
public final class CachedByteSource {

  public static let defaultWindowBytes: Int64 = 256 * 1024
  /// Enough for a `moov` atom on a typical album track.
  public static let tailPrefetchBytes: Int64 = 128 * 1024

  private let fetcher: ByteFetcher
  private let windowBytes: Int64
  private let lock = NSLock()

  private var storage: Data
  private var present = ByteRangeSet()
  private var cancelled = false
  private var length: Int64?

  /// Every range this source was asked for, in order. Diagnostic only — the
  /// spike used exactly this to discover that Apple's FLAC decoder reads from
  /// the start of the file to the seek point.
  public private(set) var requestLog: [Range<Int64>] = []

  public init(fetcher: ByteFetcher, windowBytes: Int64 = CachedByteSource.defaultWindowBytes) {
    self.fetcher = fetcher
    self.windowBytes = max(4096, windowBytes)
    self.storage = Data()
  }

  /// The size the audio parser is told. The lie that makes the design work.
  public func totalBytes() throws -> Int64 {
    lock.lock()
    if let length { lock.unlock(); return length }
    lock.unlock()

    let fetched = try fetcher.contentLength()
    lock.lock()
    length = fetched
    if storage.count < Int(fetched) {
      storage.append(Data(count: Int(fetched) - storage.count))
    }
    lock.unlock()
    return fetched
  }

  /// Contiguous bytes available from `offset` — what a buffered-ahead readout
  /// is derived from.
  public func availableBytes(from offset: Int64) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    return present.contiguousBytes(from: offset)
  }

  public func cancel() {
    lock.lock(); cancelled = true; lock.unlock()
  }

  public func resume() {
    lock.lock(); cancelled = false; lock.unlock()
  }

  /**
   Pull the end of the file in before anything else.

   Call for MP4-family containers. Cheap — one request — and without it an ALAC
   or AAC track will not open until the whole file has landed, because the
   parser's first reads are at the tail.
   */
  public func prefetchTail(bytes: Int64 = CachedByteSource.tailPrefetchBytes) throws {
    let total = try totalBytes()
    guard total > 0 else { return }
    let start = max(0, total - bytes)
    try ensure(start..<total)
  }

  /**
   The read behind `AudioFile_ReadProc`. Blocks until the bytes are present or
   the source is cancelled.

   Returns fewer bytes than asked for only at the true end of the resource,
   which is the one case Core Audio reads as end-of-file rather than an error.
   */
  public func read(offset: Int64, count: Int) throws -> Data {
    let total = try totalBytes()
    guard offset >= 0, offset < total else { return Data() }

    let end = min(offset + Int64(count), total)
    let wanted = offset..<end
    lock.lock(); requestLog.append(wanted); lock.unlock()

    try ensure(wanted)

    lock.lock(); defer { lock.unlock() }
    return storage.subdata(in: Int(wanted.lowerBound)..<Int(wanted.upperBound))
  }

  /// Fetch whatever part of `range` is missing, a window at a time.
  private func ensure(_ range: Range<Int64>) throws {
    let total = try totalBytes()

    while true {
      lock.lock()
      if cancelled { lock.unlock(); throw ByteSourceError.cancelled }
      let gap = present.firstGap(from: range.lowerBound, limit: min(range.upperBound, total))
      lock.unlock()

      guard let gap else { return }

      // Round out to a window so a parser reading a few bytes at a time does
      // not turn into a request per read.
      let windowStart = (gap.lowerBound / windowBytes) * windowBytes
      let windowEnd = min(total, max(gap.upperBound, windowStart + windowBytes))
      let toFetch = windowStart..<windowEnd

      let data: Data
      do {
        data = try fetcher.fetch(toFetch)
      } catch let error as ByteSourceError {
        throw error
      } catch {
        throw ByteSourceError.fetchFailed(String(describing: error))
      }

      lock.lock()
      if cancelled { lock.unlock(); throw ByteSourceError.cancelled }
      let landed = Int64(data.count)
      if landed > 0 {
        let upper = min(toFetch.lowerBound + landed, total)
        storage.replaceSubrange(Int(toFetch.lowerBound)..<Int(upper), with: data.prefix(Int(upper - toFetch.lowerBound)))
        present.insert(toFetch.lowerBound..<upper)
      }
      lock.unlock()

      // A fetch that returns nothing would otherwise spin forever.
      if landed == 0 { throw ByteSourceError.fetchFailed("empty response for \(toFetch)") }
    }
  }
}
