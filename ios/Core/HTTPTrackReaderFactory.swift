import Foundation
import AudioToolbox

/**
 Turns a `Track` into something decodable, picking the transport.

 This is the one place that knows there are two, and the choice is not a
 setting — it is discovered. A direct stream answers a ranged request with 206
 and a length, and gets the random-access cache. A transcoding endpoint answers
 200, `accept-ranges: none`, and often no length at all, and gets the
 sequential one. Measured against a real Navidrome; see docs/architecture.md §10.

 The app does not choose deliberately either: yuzic sends `format`/`maxBitRate`
 for every quality except Original, and that setting is per-network. So the same
 track is randomly accessible on WiFi at Original and forward-only on cellular
 at 192kbps, and nothing above here should have to care.
 */
public final class HTTPTrackReaderFactory: TrackReaderFactory {

  /// Bits per second assumed when a transcoding server will not say how long
  /// its output is. Only used to answer `GetSizeProc` before the stream ends —
  /// erring high is deliberate, since reading past the real end reads as
  /// end-of-file while under-reporting truncates the track.
  public static let assumedBitrate: Double = 320_000

  /**
   Where fetched audio is kept between tracks. Nil keeps the old behaviour —
   in memory, for the life of the track — which is what the tests want and
   what a host that never calls `configureCache` gets.

   Only the ranged path is cached. A transcoded stream is produced on the fly
   and its bytes are not the file: two plays at different bitrates are
   different audio under the same id, and storing either as *the* cached copy
   would serve the wrong one back.
   */
  private let cache: DiskCache?

  public init(cache: DiskCache? = nil) {
    self.cache = cache
  }

  public func makeReader(for track: Track) throws -> TrackReader {
    let source = try makeSource(for: track)
    let reader = AudioFileReader(source: source)
    try reader.open(hint: Self.typeHint(for: track.uri))
    return reader
  }

  func makeSource(for track: Track) throws -> ByteSource {
    guard let url = URL(string: track.uri) else {
      throw ByteSourceError.fetchFailed("unusable uri: \(track.uri)")
    }

    if url.isFileURL {
      // A downloaded track. Whole and seekable, so the ranged path with a
      // trivially cheap fetcher.
      return CachedByteSource(fetcher: try FileByteFetcher(url: url))
    }

    let fetcher = HTTPByteFetcher(url: url, headers: track.headers)
    do {
      _ = try fetcher.contentLength()
    } catch {
      // No length means a transcode in progress, not a broken server.
      return streamingSource(url: url, track: track)
    }

    if fetcher.rangesSupported == false {
      return streamingSource(url: url, track: track)
    }

    let source = CachedByteSource(fetcher: fetcher, cache: cache, cacheId: track.id)
    // MP4-family containers keep `moov` at the tail unless written faststart,
    // and the parser's first reads go there. Without this an ALAC or AAC track
    // will not open until the whole file has landed — confirmed in the spike.
    if Self.isMP4Family(url: url) {
      try? source.prefetchTail()
    }
    return source
  }

  private func streamingSource(url: URL, track: Track) -> ByteSource {
    let seconds = track.durationSec ?? 0
    let estimate = seconds > 0
      ? Int64(seconds * Self.assumedBitrate / 8)
      : Int64(64 * 1024 * 1024)
    let producer = HTTPStreamProducer(url: url, headers: track.headers)
    return StreamingByteSource(producer: producer, estimatedBytes: estimate)
  }

  /// Saves the parser sniffing, which costs extra reads at the head — and here
  /// a read is a network request rather than a memcpy.
  static func typeHint(for uri: String) -> AudioFileTypeID {
    switch (uri as NSString).pathExtension.lowercased() {
    case "mp3": return kAudioFileMP3Type
    case "m4a", "mp4", "aac": return kAudioFileM4AType
    case "flac": return kAudioFileFLACType
    case "wav": return kAudioFileWAVEType
    case "aif", "aiff": return kAudioFileAIFFType
    default: return 0
    }
  }

  static func isMP4Family(url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if ["m4a", "mp4", "m4b", "aac"].contains(ext) { return true }
    // Subsonic-style URLs carry the format in the query rather than the path.
    let query = url.query?.lowercased() ?? ""
    return query.contains("format=m4a") || query.contains("format=aac")
  }
}

/// A local file, behind the same interface as the network. Lets a downloaded
/// track and a streamed one take exactly the same path.
final class FileByteFetcher: ByteFetcher, @unchecked Sendable {
  private let handle: FileHandle
  private let size: Int64

  init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  deinit { try? handle.close() }

  func contentLength() throws -> Int64 { size }

  func fetch(_ range: Range<Int64>) throws -> Data {
    try handle.seek(toOffset: UInt64(range.lowerBound))
    let count = Int(min(range.upperBound, size) - range.lowerBound)
    guard count > 0 else { return Data() }
    return handle.readData(ofLength: count)
  }
}
